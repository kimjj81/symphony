defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.OrchestrationBrief
  alias SymphonyElixir.Codex.TaskClassifier
  alias SymphonyElixir.{Config, PromptBuilder, StateManager, Tracker, TransitionIntent}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.{TransitionJournal, WorkerOutcome, Workspace}

  @type worker_host :: String.t() | nil

  @worker_outcome_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["kind", "summary_ko", "evidence", "head_oid", "findings"],
    "properties" => %{
      "kind" => %{
        "type" => "string",
        "enum" => Enum.map(WorkerOutcome.kinds(), &Atom.to_string/1)
      },
      "summary_ko" => %{"type" => "string", "minLength" => 1},
      "evidence" => %{"type" => "array", "items" => %{"type" => "string"}},
      "head_oid" => %{"type" => ["string", "null"]},
      "findings" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()} | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        maybe_raise_agent_error(issue, reason, opts)
    end
  end

  defp maybe_raise_agent_error(issue, reason, opts) do
    if Keyword.get(opts, :raise_on_error, true) do
      raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    else
      {:error, reason}
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case prepare_agent_workspace(issue, worker_host) do
      {:ok, workspace, app_server_opts} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- maybe_run_before_run_hook(workspace, issue, worker_host, app_server_opts) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts)
          end
        after
          maybe_run_after_run_hook(workspace, issue, worker_host, app_server_opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_agent_workspace(%Issue{kind: :issue, state: state_name} = issue, nil)
       when is_binary(state_name) do
    if Config.source_checkout_state?(state_name) do
      with {:ok, source_checkout} <- Workspace.prepare_source_checkout_for_issue(issue) do
        {:ok, source_checkout,
         [
           runtime_overrides: %{
             thread_sandbox: "read-only",
             turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
           },
           skip_workspace_hooks: true
         ]}
      end
    else
      prepare_issue_workspace(issue, nil)
    end
  end

  defp prepare_agent_workspace(issue, worker_host), do: prepare_issue_workspace(issue, worker_host)

  defp prepare_issue_workspace(issue, worker_host) do
    with {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace, []}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp codex_message_handler(recipient, issue, metrics) do
    fn message ->
      record_turn_metrics(message, metrics)
      send_codex_update(recipient, issue, message)
    end
  end

  defp command_started?(%{event: :notification} = message) do
    method = message |> notification_payload() |> then(&(Map.get(&1, "method") || Map.get(&1, :method)))
    method in ["item/commandExecution/started", "codex/event/exec_command_begin"]
  end

  defp command_started?(_message), do: false

  defp record_turn_metrics(message, metrics) do
    if command_started?(message), do: :atomics.add(metrics, 1, 1)

    case token_usage_from_message(message) do
      %{} = usage ->
        :atomics.put(metrics, 2, token_value(usage, "input_tokens"))
        :atomics.put(metrics, 3, token_value(usage, "cached_input_tokens"))
        :atomics.put(metrics, 4, token_value(usage, "total_tokens"))

      _ ->
        :ok
    end
  end

  defp token_usage_from_message(%{event: :notification} = message) do
    payload = notification_payload(message)

    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]
    |> Enum.find_value(&map_at_path(payload, &1))
  end

  defp token_usage_from_message(_message), do: nil

  defp notification_payload(message) do
    envelope = Map.get(message, :payload) || Map.get(message, "payload") || %{}
    Map.get(envelope, :payload) || Map.get(envelope, "payload") || envelope
  end

  defp token_value(usage, key) do
    keys =
      case key do
        "input_tokens" -> ["input_tokens", :input_tokens, "inputTokens", :inputTokens]
        "cached_input_tokens" -> ["cached_input_tokens", :cached_input_tokens, "cachedInputTokens", :cachedInputTokens]
        "total_tokens" -> ["total_tokens", :total_tokens, "totalTokens", :totalTokens]
      end

    case Enum.find_value(keys, &Map.get(usage, &1)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp map_at_path(map, []), do: if(is_map(map), do: map)

  defp map_at_path(map, [key | rest]) when is_map(map) do
    map
    |> Map.get(key)
    |> map_at_path(rest)
  end

  defp map_at_path(_map, _path), do: nil

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_runtime_observation(recipient, %Issue{id: issue_id}, event, payload)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {
      :codex_worker_update,
      issue_id,
      %{event: event, payload: payload, timestamp: System.system_time(:millisecond)}
    })

    :ok
  end

  defp send_runtime_observation(_recipient, _issue, _event, _payload), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp maybe_run_before_run_hook(workspace, issue, worker_host, app_server_opts) do
    if Keyword.get(app_server_opts, :skip_workspace_hooks, false) do
      :ok
    else
      Workspace.run_before_run_hook(workspace, issue, worker_host)
    end
  end

  defp maybe_run_after_run_hook(workspace, issue, worker_host, app_server_opts) do
    if Keyword.get(app_server_opts, :skip_workspace_hooks, false) do
      :ok
    else
      Workspace.run_after_run_hook(workspace, issue, worker_host)
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts) do
    if Config.settings!().agent.orchestration_brief_enabled do
      run_briefed_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts)
    else
      run_legacy_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts)
    end
  end

  defp run_legacy_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    task_profile = select_codex_task_profile(issue)

    Logger.info([
      "Selected Codex task profile for #{issue_context(issue)}",
      " task_type=#{task_profile.task_type}",
      " model=#{task_profile.model}",
      " effort=#{task_profile.effort}"
    ])

    app_server_opts =
      app_server_opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:codex_command, task_profile.command)

    opts = Keyword.put(opts, :codex_task_profile, task_profile)

    with {:ok, session} <- AppServer.start_session(workspace, app_server_opts) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_briefed_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts) do
    if Config.settings!().state_manager.mode == "authoritative" do
      run_authoritative_briefed_codex_turn(
        workspace,
        issue,
        codex_update_recipient,
        opts,
        worker_host,
        app_server_opts
      )
    else
      run_legacy_briefed_codex_turns(
        workspace,
        issue,
        codex_update_recipient,
        opts,
        worker_host,
        app_server_opts
      )
    end
  end

  defp run_legacy_briefed_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, app_server_opts) do
    settings = Config.settings!()
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    max_review_verdicts = Keyword.get(opts, :max_review_verdicts, settings.agent.max_review_verdicts)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    lane_issue = restore_dispatch_state(issue)

    brief_opts =
      opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, lane_issue))

    {brief, brief_meta} =
      case OrchestrationBrief.generate(workspace, lane_issue, brief_opts) do
        {:ok, generated, metadata} ->
          {generated, metadata}

        {:error, reason} ->
          fallback = OrchestrationBrief.fallback(lane_issue)
          Logger.warning("Orchestration brief generation failed for #{issue_context(lane_issue)}; using deterministic fallback reason=#{inspect(reason)}")
          {fallback, %{source: :fallback, bytes: byte_size(fallback), lane: lane_issue.state}}
      end

    Logger.info([
      "Prepared orchestration brief for #{issue_context(lane_issue)}",
      " source=#{brief_meta.source}",
      " bytes=#{brief_meta.bytes}",
      " lane=#{brief_meta.lane}"
    ])

    send_runtime_observation(codex_update_recipient, lane_issue, :orchestration_brief, brief_meta)

    context = %{
      workspace: workspace,
      recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      app_server_opts: app_server_opts,
      brief: brief,
      worker_host: worker_host,
      max_turns: max_turns,
      max_review_verdicts: max_review_verdicts
    }

    do_run_briefed_turns(context, lane_issue, 1, 0)
  end

  defp run_authoritative_briefed_codex_turn(
         workspace,
         tracker_issue,
         codex_update_recipient,
         opts,
         worker_host,
         app_server_opts
       ) do
    settings = Config.settings!()
    lane_issue = restore_dispatch_state(tracker_issue)
    max_review_verdicts = Keyword.get(opts, :max_review_verdicts, settings.agent.max_review_verdicts)
    review_attempt = Keyword.get(opts, :review_attempt, next_review_attempt(tracker_issue.id))

    brief_opts =
      opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:on_message, codex_message_handler(codex_update_recipient, lane_issue))

    case OrchestrationBrief.generate(workspace, lane_issue, brief_opts) do
      {:ok, brief, _brief_meta} ->
        run_authoritative_worker(%{
          workspace: workspace,
          tracker_issue: tracker_issue,
          lane_issue: lane_issue,
          brief: brief,
          codex_update_recipient: codex_update_recipient,
          opts: opts,
          worker_host: worker_host,
          app_server_opts: app_server_opts,
          review_attempt: review_attempt,
          max_review_verdicts: max_review_verdicts
        })

      {:error, reason} ->
        request_preflight_handoff_transition(tracker_issue, reason, opts)
    end
  end

  defp run_authoritative_worker(context) do
    %{
      workspace: workspace,
      tracker_issue: tracker_issue,
      lane_issue: lane_issue,
      brief: brief,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      worker_host: worker_host,
      app_server_opts: app_server_opts,
      review_attempt: review_attempt,
      max_review_verdicts: max_review_verdicts
    } = context

    task_profile = select_briefed_task_profile(lane_issue)
    verification_tier = verification_tier(lane_issue.state)

    prompt =
      build_briefed_turn_prompt(
        lane_issue,
        brief,
        verification_tier,
        review_attempt,
        max_review_verdicts
      )

    session_opts =
      app_server_opts
      |> Keyword.put(:worker_host, worker_host)
      |> Keyword.put(:codex_command, task_profile.command)

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      try do
        with {:ok, turn_session} <-
               AppServer.run_turn(session, prompt, lane_issue,
                 on_message: codex_message_handler(codex_update_recipient, lane_issue),
                 model: task_profile.model,
                 effort: task_profile.effort,
                 output_schema: @worker_outcome_schema
               ),
             {:ok, outcome} <- decode_worker_outcome(turn_session),
             result <-
               request_worker_outcome_transition(
                 tracker_issue,
                 outcome,
                 turn_session,
                 review_attempt,
                 max_review_verdicts,
                 opts
               ) do
          normalize_worker_transition_result(result)
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp request_preflight_handoff_transition(tracker_issue, reason, opts) do
    metadata = tracker_issue.metadata || %{}

    dispatch_transition_id =
      metadata["symphony_transition_id"] || metadata[:symphony_transition_id]

    intent = %TransitionIntent{
      id: "preflight-handoff:#{tracker_issue.id}:#{dispatch_transition_id || "missing-causation"}",
      issue_id: tracker_issue.id,
      source: :orchestrator,
      actor: "symphony",
      expected_state: tracker_issue.state,
      kind: :handoff_required,
      head_oid: metadata["head_oid"] || metadata[:head_oid],
      causation_id: dispatch_transition_id,
      work_item_kind: tracker_issue.kind,
      comment_body:
        "Symphony orchestration preflight을 완료하지 못해 작업 에이전트를 시작하지 않고 사람 검토로 인계합니다.\n\n" <>
          "- 사유: #{inspect(reason)}"
    }

    requester = Keyword.get(opts, :state_manager_requester)

    result =
      if is_function(requester, 1) do
        requester.(intent)
      else
        StateManager.request(Keyword.get(opts, :state_manager, SymphonyElixir.Orchestrator), intent)
      end

    normalize_worker_transition_result(result)
  end

  defp decode_worker_outcome(turn_session) do
    with message when is_binary(message) <- Map.get(turn_session, :final_agent_message),
         {:ok, payload} <- Jason.decode(message),
         {:ok, outcome} <- WorkerOutcome.new(payload) do
      {:ok, outcome}
    else
      nil -> {:error, :missing_worker_outcome}
      {:error, reason} -> {:error, {:invalid_worker_outcome, reason}}
      _ -> {:error, :invalid_worker_outcome}
    end
  end

  defp request_worker_outcome_transition(
         tracker_issue,
         outcome,
         turn_session,
         review_attempt,
         review_limit,
         opts
       ) do
    session_id = Map.fetch!(turn_session, :session_id)

    dispatch_transition_id =
      tracker_issue.metadata &&
        (tracker_issue.metadata["symphony_transition_id"] || tracker_issue.metadata[:symphony_transition_id])

    intent = %TransitionIntent{
      id: "worker:#{tracker_issue.id}:#{session_id}",
      issue_id: tracker_issue.id,
      source: :worker,
      actor: "codex-worker",
      expected_state: tracker_issue.state,
      kind: outcome.kind,
      head_oid: outcome.head_oid,
      causation_id: dispatch_transition_id || session_id,
      work_item_kind: tracker_issue.kind,
      review_attempt: review_attempt,
      review_limit: review_limit,
      comment_body: render_worker_outcome_comment(outcome),
      metadata: %{
        evidence: outcome.evidence,
        findings: outcome.findings,
        dispatch_transition_id: dispatch_transition_id,
        session_id: session_id
      }
    }

    requester = Keyword.get(opts, :state_manager_requester)

    if is_function(requester, 1) do
      requester.(intent)
    else
      StateManager.request(Keyword.get(opts, :state_manager, SymphonyElixir.Orchestrator), intent)
    end
  end

  defp render_worker_outcome_comment(outcome) do
    evidence = render_outcome_list("검증", outcome.evidence)
    findings = render_outcome_list("발견 사항", outcome.findings)

    [outcome.summary_ko, evidence, findings]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp next_review_attempt(issue_id) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) ->
        completed_reviews =
          pid
          |> TransitionJournal.replay()
          |> Enum.reverse()
          |> Enum.take_while(&(not review_lifecycle_boundary?(&1, issue_id)))
          |> Enum.count(&completed_review?(&1, issue_id))

        completed_reviews + 1

      _ ->
        1
    end
  end

  defp completed_review?(event, issue_id) do
    event.phase == :verified and event.data[:issue_id] == issue_id and
      event.data[:kind] in [:clean_review, :review_findings]
  end

  defp review_lifecycle_boundary?(event, issue_id) do
    event.phase == :verified and event.data[:issue_id] == issue_id and
      event.data[:kind] in [
        :dispatch_implementation,
        {:operator_request, :planned},
        {:operator_request, :reopen}
      ]
  end

  defp render_outcome_list(_title, []), do: nil

  defp render_outcome_list(title, entries) do
    title <> "\n" <> Enum.map_join(entries, "\n", &("- " <> to_string(&1)))
  end

  defp normalize_worker_transition_result({:ok, _applied}), do: :ok
  defp normalize_worker_transition_result({:noop, _reason}), do: :ok
  defp normalize_worker_transition_result({:conflict, _snapshot}), do: :ok
  defp normalize_worker_transition_result({:error, {:transition_retry_scheduled, _reason}}), do: :ok
  defp normalize_worker_transition_result({:rejected, reason}), do: {:error, {:worker_outcome_rejected, reason}}
  defp normalize_worker_transition_result({:error, reason}), do: {:error, {:worker_transition_failed, reason}}
  defp normalize_worker_transition_result(other), do: {:error, {:invalid_worker_transition_result, other}}

  defp restore_dispatch_state(%Issue{metadata: metadata} = issue) when is_map(metadata) do
    case Map.get(metadata, "symphony_dispatch_state") || Map.get(metadata, :symphony_dispatch_state) do
      state when is_binary(state) and state != "" -> %{issue | state: state}
      _ -> issue
    end
  end

  defp restore_dispatch_state(issue), do: issue

  defp do_run_briefed_turns(context, issue, turn_number, review_verdicts) do
    %{max_turns: max_turns, max_review_verdicts: max_review_verdicts} = context
    task_profile = select_briefed_task_profile(issue)
    verification_tier = verification_tier(issue.state)
    review_attempt = if review_state?(issue.state), do: review_verdicts + 1, else: review_verdicts
    prompt = build_briefed_turn_prompt(issue, context.brief, verification_tier, review_attempt, max_review_verdicts)
    metrics = :atomics.new(4, signed: false)

    Logger.info([
      "Starting briefed worker for #{issue_context(issue)}",
      " turn=#{turn_number}/#{max_turns}",
      " task_type=#{task_profile.task_type}",
      " model=#{task_profile.model}",
      " effort=#{task_profile.effort}",
      " verification_tier=#{verification_tier}",
      " review_verdict=#{review_attempt}/#{max_review_verdicts}",
      " prompt_bytes=#{byte_size(prompt)}"
    ])

    session_opts =
      context.app_server_opts
      |> Keyword.put(:worker_host, context.worker_host)
      |> Keyword.put(:codex_command, task_profile.command)

    with {:ok, session} <- AppServer.start_session(context.workspace, session_opts) do
      turn_result =
        try do
          AppServer.run_turn(
            session,
            prompt,
            issue,
            on_message: codex_message_handler(context.recipient, issue, metrics),
            model: task_profile.model,
            effort: task_profile.effort
          )
        after
          AppServer.stop_session(session)
        end

      with {:ok, turn_session} <- turn_result,
           {:ok, refreshed_issue} <- refresh_issue(issue, context.issue_state_fetcher) do
        completed_review_verdicts = completed_review_verdicts(issue, review_verdicts)

        Logger.info([
          "Completed briefed worker for #{issue_context(issue)}",
          " session_id=#{turn_session[:session_id]}",
          " turn=#{turn_number}/#{max_turns}",
          " commands=#{:atomics.get(metrics, 1)}",
          " input_tokens=#{:atomics.get(metrics, 2)}",
          " cached_input_tokens=#{:atomics.get(metrics, 3)}",
          " verification_tier=#{verification_tier}",
          " transition=#{issue.state}->#{refreshed_issue.state}"
        ])

        send_runtime_observation(context.recipient, issue, :briefed_worker_metrics, %{
          commands: :atomics.get(metrics, 1),
          input_tokens: :atomics.get(metrics, 2),
          cached_input_tokens: :atomics.get(metrics, 3),
          total_tokens: :atomics.get(metrics, 4),
          verification_tier: verification_tier,
          review_verdict: review_attempt,
          prompt_bytes: byte_size(prompt),
          transition: "#{issue.state}->#{refreshed_issue.state}"
        })

        handle_briefed_transition(
          context,
          issue,
          refreshed_issue,
          turn_number,
          completed_review_verdicts
        )
      end
    end
  end

  defp completed_review_verdicts(issue, review_verdicts) do
    if review_state?(issue.state), do: review_verdicts + 1, else: review_verdicts
  end

  defp handle_briefed_transition(context, issue, refreshed_issue, turn_number, review_verdicts) do
    case briefed_transition(issue, refreshed_issue, review_verdicts, context.max_review_verdicts) do
      {:done, reason} ->
        Logger.info("Briefed run completed for #{issue_context(refreshed_issue)} reason=#{reason}")
        :ok

      {:continue, reason} when turn_number < context.max_turns ->
        Logger.info("Continuing briefed run for #{issue_context(refreshed_issue)} reason=#{reason}")
        do_run_briefed_turns(context, refreshed_issue, turn_number + 1, review_verdicts)

      {:continue, _reason} ->
        handoff_to_human_review(
          refreshed_issue,
          "안전 turn 한도(#{context.max_turns}회)에 도달해 자동 실행을 중단합니다.",
          context.opts
        )

      {:handoff, reason} ->
        handoff_to_human_review(refreshed_issue, reason, context.opts)
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    task_profile = Keyword.fetch!(opts, :codex_task_profile)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             model: task_profile.model,
             effort: task_profile.effort
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp select_codex_task_profile(issue) do
    settings = Config.settings!()
    task_type = TaskClassifier.classify(issue)
    profiles = settings.codex.task_profiles
    profile = Map.get(profiles, task_type) || Map.fetch!(profiles, "default")

    %{
      task_type: task_type,
      command: Map.fetch!(profile, "command"),
      model: Map.fetch!(profile, "model"),
      effort: Map.fetch!(profile, "effort")
    }
  end

  defp select_briefed_task_profile(issue) do
    task_type =
      cond do
        review_state?(issue.state) -> "review"
        rework_state?(issue.state) -> "single_file_edit"
        true -> TaskClassifier.classify(issue)
      end

    profiles = Config.settings!().codex.task_profiles
    profile = Map.get(profiles, task_type) || Map.fetch!(profiles, "default")

    %{
      task_type: task_type,
      command: Map.fetch!(profile, "command"),
      model: Map.fetch!(profile, "model"),
      effort: Map.fetch!(profile, "effort")
    }
  end

  defp build_briefed_turn_prompt(issue, brief, verification_tier, review_attempt, max_review_verdicts) do
    review_guidance =
      cond do
        review_state?(issue.state) and review_attempt >= max_review_verdicts ->
          "This is review verdict #{review_attempt} of #{max_review_verdicts}. If any finding remains, return review_findings with a Korean blocker summary. Return clean_review when there are no findings. Symphony decides and applies the tracker transition."

        review_state?(issue.state) ->
          "This is review verdict #{review_attempt} of #{max_review_verdicts}. Return clean_review when there are no findings, or review_findings only for actionable findings. Symphony decides and applies the tracker transition."

        true ->
          "Complete only the current lane and return the matching semantic outcome. Symphony decides and applies the tracker transition."
      end

    verification_guidance =
      if verification_tier == :full do
        "Run the repository-defined full local verification bundle. Symphony validates required CI before merge completion."
      else
        "Run only focused verification directly covering changed files. Use any CI snapshot supplied in the brief without polling GitHub. Do not run full API/Web/OpenAPI/Astro suites or Compose/seed unless the exact finding cannot be verified more narrowly. Retry browser or environment failures at most once, then report partial coverage."
      end

    """
    Symphony worker execution contract

    Tracker: #{issue.identifier} | #{issue.title}
    State: #{issue.state}
    URL: #{issue.url}
    Verification tier: #{verification_tier}

    ORCHESTRATION BRIEF
    #{brief}

    The orchestration preflight already read and applied the long conductor, review, GitHub-review
    skills and their reference documents. Do not reopen those documents. Read a repository skill or
    reference only if this brief names it explicitly and the current live state cannot be handled
    without it. Treat the supplied live head and GitHub feedback as the tracker snapshot for this
    dispatch. Use git to stop on branch-head drift before pushing, but do not query or mutate GitHub.
    Keep the change literal to the brief.

    #{review_guidance}
    #{verification_guidance}

    Finish by returning exactly one structured semantic outcome. Do not post tracker comments,
    add or remove workflow labels, close or reopen items, or merge pull requests. Symphony owns all
    tracker responses and state transitions.
    """
  end

  defp verification_tier(state_name) do
    normalized_state = normalize_issue_state(state_name)

    if Enum.any?(Config.settings!().verification.full_states, &(normalize_issue_state(&1) == normalized_state)) do
      :full
    else
      :focused
    end
  end

  defp review_state?(state_name) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(Config.settings!().agent.review_states, &(normalize_issue_state(&1) == normalized_state))
  end

  defp rework_state?(state_name) do
    normalize_issue_state(state_name) == normalize_issue_state(Config.settings!().agent.rework_state)
  end

  defp human_review_state?(state_name) do
    normalize_issue_state(state_name) == normalize_issue_state(Config.settings!().agent.human_review_state)
  end

  defp briefed_transition(previous_issue, refreshed_issue, review_verdicts, max_review_verdicts) do
    previous_state = previous_issue.state
    refreshed_state = refreshed_issue.state

    cond do
      human_review_state?(refreshed_state) ->
        {:done, :human_review}

      full_verification_state?(previous_state) and not active_issue_state?(refreshed_state) ->
        {:done, :non_active_state}

      not active_issue_state?(refreshed_state) ->
        {:handoff, "Symphony 실행 계약과 다른 종료 상태 전이(#{previous_state} -> #{refreshed_state})가 발생해 자동 실행을 중단합니다."}

      true ->
        active_briefed_transition(previous_state, refreshed_state, review_verdicts, max_review_verdicts)
    end
  end

  defp active_briefed_transition(previous_state, refreshed_state, review_verdicts, max_review_verdicts) do
    cond do
      review_state?(previous_state) ->
        review_briefed_transition(previous_state, refreshed_state, review_verdicts, max_review_verdicts)

      review_state?(refreshed_state) ->
        if rework_state?(previous_state), do: {:continue, :rework_completed}, else: {:continue, :review_requested}

      true ->
        invalid_active_transition(previous_state, refreshed_state)
    end
  end

  defp review_briefed_transition(previous_state, refreshed_state, review_verdicts, max_review_verdicts) do
    cond do
      not rework_state?(refreshed_state) ->
        invalid_active_transition(previous_state, refreshed_state)

      review_verdicts >= max_review_verdicts ->
        {:handoff, "자동 리뷰 판정 한도(#{max_review_verdicts}회)에 도달했지만 해결되지 않은 finding이 남아 Human Review로 전환합니다."}

      true ->
        {:continue, :review_findings}
    end
  end

  defp invalid_active_transition(previous_state, refreshed_state) do
    {:handoff, "Symphony 실행 계약과 다른 active 상태 전이(#{previous_state} -> #{refreshed_state})가 발생해 자동 반복을 중단합니다."}
  end

  defp full_verification_state?(state_name) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(Config.settings!().verification.full_states, &(normalize_issue_state(&1) == normalized_state))
  end

  defp refresh_issue(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} -> {:ok, refreshed_issue}
      {:ok, []} -> {:ok, issue}
      {:error, reason} -> {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp refresh_issue(issue, _issue_state_fetcher), do: {:ok, issue}

  defp handoff_to_human_review(%Issue{id: issue_id} = issue, reason, opts) when is_binary(issue_id) do
    commenter = Keyword.get(opts, :tracker_commenter, &Tracker.create_comment/2)

    state_updater =
      Keyword.get(opts, :tracker_state_updater, fn id, state ->
        Tracker.adapter().update_issue_state(id, state)
      end)

    target_state = Config.settings!().agent.human_review_state
    body = "Symphony 자동 실행 중단\n\n#{reason}"

    with :ok <- normalize_handoff_comment(commenter.(issue_id, body)),
         :ok <- normalize_handoff_state_update(state_updater.(issue_id, target_state)) do
      Logger.info("Moved #{issue_context(issue)} to #{target_state} after briefed-run handoff")
      :ok
    end
  end

  defp handoff_to_human_review(_issue, reason, _opts), do: {:error, {:human_review_handoff_failed, reason}}

  defp normalize_handoff_comment(:ok), do: :ok
  defp normalize_handoff_comment({:error, reason}), do: {:error, {:human_review_comment_failed, reason}}
  defp normalize_handoff_comment(other), do: {:error, {:human_review_comment_failed, other}}

  defp normalize_handoff_state_update(:ok), do: :ok
  defp normalize_handoff_state_update({:error, reason}), do: {:error, {:human_review_handoff_failed, reason}}
  defp normalize_handoff_state_update(other), do: {:error, {:human_review_handoff_failed, other}}

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
