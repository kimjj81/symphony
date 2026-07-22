defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    AppliedTransition,
    Config,
    StatusDashboard,
    Tracker,
    TransitionIntent,
    TransitionJournal,
    TransitionPlan,
    WorkflowStatePolicy,
    Workspace
  }

  alias SymphonyElixir.Notifications.{Cmux, Discord}
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @max_failure_retry_attempts 5
  @transition_effect_retry_ms 2_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      cleanup_retries: %{},
      last_transition: nil,
      transition_conflicts: 0,
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    state = run_terminal_workspace_cleanup(state)
    state = schedule_tick(state, 0)

    if config.state_manager.mode in ["shadow", "authoritative"] do
      {:ok, state, {:continue, :replay_transition_journal}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:replay_transition_journal, state) do
    :ok = fence_inherited_worker_tasks()
    {:noreply, replay_pending_transitions(state)}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:refresh_issue, issue_id}, state) when is_binary(issue_id) do
    state = refresh_runtime_config(state)

    state =
      case Tracker.fetch_issue_states_by_ids([issue_id]) do
        {:ok, [%Issue{} = issue | _]} ->
          handle_targeted_issue_refresh(state, issue)

        {:ok, []} ->
          Logger.info("Targeted issue refresh found no visible issue: issue_id=#{issue_id}")
          release_issue_claim(state, issue_id)

        {:error, reason} ->
          Logger.warning("Targeted issue refresh failed: issue_id=#{issue_id} reason=#{inspect(reason)}")

          state
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              notify_latest_issue_state_after_agent_completion(issue_id, running_entry)

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:agent_run_failed, issue_id, reason}, state) when is_binary(issue_id) do
    case Map.has_key?(state.running, issue_id) do
      false ->
        {:noreply, state}

      true ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        ref = Map.get(running_entry, :ref)

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        Logger.warning("Agent run failed for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state =
          schedule_issue_retry(state, issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "agent run failed: #{inspect(reason)}",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path)
          })

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:retry_transition_effect, transition_id, attempt}, state) do
    {result, state} = retry_transition_effect(transition_id, state)

    state = handle_transition_effect_retry_result(state, transition_id, attempt, result)

    Logger.info("Transition effect retry completed transition_id=#{transition_id} attempt=#{attempt} result=#{inspect(result)}")

    {:noreply, state}
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:retry_cleanup, issue_id, retry_token}, state) when is_binary(issue_id) do
    state =
      case pop_cleanup_retry_state(state, issue_id, retry_token) do
        {:ok, retry_entry, state} -> handle_cleanup_retry(state, issue_id, retry_entry)
        :missing -> state
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_transition_effect_retry_result(state, transition_id, attempt, {:error, _reason})
       when attempt < @max_failure_retry_attempts do
    Process.send_after(
      self(),
      {:retry_transition_effect, transition_id, attempt + 1},
      @transition_effect_retry_ms
    )

    state
  end

  defp handle_transition_effect_retry_result(state, transition_id, _attempt, {:error, reason}) do
    if String.starts_with?(transition_id, "effect-retry-exhausted:") do
      Logger.error("Exhausted retry for a handoff transition transition_id=#{transition_id} reason=#{inspect(reason)}")

      state
    else
      handoff_exhausted_transition_effect(state, transition_id, reason)
    end
  end

  defp handle_transition_effect_retry_result(state, transition_id, _attempt, result) do
    _ = maybe_finalize_abandoned_cause(transition_id, result)
    state
  end

  defp maybe_finalize_abandoned_cause(
         "effect-retry-exhausted:" <> _rest = handoff_id,
         {:ok, _applied}
       ) do
    with {:ok, snapshot} <- journal_snapshot(handoff_id),
         cause_id when is_binary(cause_id) and cause_id != "" <- snapshot.data[:causation_id] do
      normalize_journal_record(
        journal_record(cause_id, :verified, %{
          issue_id: snapshot.data[:issue_id],
          abandoned_effect: true,
          handoff_transition_id: handoff_id
        })
      )
    else
      _ -> :ok
    end
  end

  defp maybe_finalize_abandoned_cause(_transition_id, _result), do: :ok

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    # Tracker reads deliberately remain available when Forgejo preflight is not
    # ready.  `Tracker.write_ready?/0` fences every broker write and dispatch
    # effect, while polling keeps the dashboard and journal recovery useful.
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      choose_issues(issues, state)
    else
      {:error, :missing_tracker_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_github_owner} ->
        Logger.error("GitHub owner missing in WORKFLOW.md")
        state

      {:error, :missing_github_repo} ->
        Logger.error("GitHub repo missing in WORKFLOW.md")
        state

      {:error, :missing_forgejo_endpoint} ->
        Logger.error("Forgejo API endpoint missing in WORKFLOW.md")
        state

      {:error, {:invalid_forgejo_endpoint, endpoint}} ->
        Logger.error("Forgejo API endpoint must end in /api/v1: #{inspect(endpoint)}")
        state

      {:error, :missing_forgejo_owner} ->
        Logger.error("Forgejo owner missing in WORKFLOW.md")
        state

      {:error, :missing_forgejo_repo} ->
        Logger.error("Forgejo repo missing in WORKFLOW.md")
        state

      {:error, {:unsupported_forgejo_major, actual, expected}} ->
        Logger.error("Unsupported Forgejo API major=#{inspect(actual)} expected=#{expected}; dispatch remains disabled")

        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_prepare_pull_request_for_issue_for_test(Issue.t(), term()) :: boolean()
  def should_prepare_pull_request_for_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_prepare_pull_request_for_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_targeted_issue_refresh_for_test(term(), Issue.t()) :: term()
  def handle_targeted_issue_refresh_for_test(%State{} = state, %Issue{} = issue) do
    handle_targeted_issue_refresh(state, issue)
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec mark_issue_in_progress_for_dispatch_for_test(Issue.t()) ::
          {:ok, Issue.t()} | {:error, term()}
  def mark_issue_in_progress_for_dispatch_for_test(%Issue{} = issue) do
    mark_issue_for_dispatch(issue)
  end

  @doc false
  @spec worker_dispatch_lease_id_for_test(Issue.t(), integer() | nil) :: String.t()
  def worker_dispatch_lease_id_for_test(%Issue{} = issue, attempt) do
    worker_dispatch_lease_id(issue, attempt)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec notify_latest_issue_state_after_agent_completion_for_test(String.t(), map()) :: :ok
  def notify_latest_issue_state_after_agent_completion_for_test(issue_id, running_entry)
      when is_binary(issue_id) and is_map(running_entry) do
    notify_latest_issue_state_after_agent_completion(issue_id, running_entry)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        state
        |> notify_issue_state_transition(issue)
        |> terminate_running_issue(issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        state
        |> notify_issue_state_transition(issue)
        |> refresh_running_issue_state(issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        state
        |> notify_issue_state_transition(issue)
        |> terminate_running_issue(issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp handle_targeted_issue_refresh(%State{} = state, %Issue{} = issue) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    cond do
      Map.has_key?(state.running, issue.id) ->
        reconcile_issue_state(issue, state, active_states, terminal_states)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Targeted issue refresh found terminal issue: #{issue_context(issue)} state=#{issue.state}; removing associated workspace")

        state
        |> attempt_terminal_workspace_cleanup(issue.id, issue.identifier, nil, 1)
        |> release_issue_claim(issue.id)

      should_prepare_pull_request_for_issue?(issue, state, active_states, terminal_states) ->
        prepare_pull_request_for_issue(state, issue)

      should_dispatch_issue?(issue, state, active_states, terminal_states) ->
        dispatch_issue(state, issue)

      true ->
        Logger.debug("Targeted issue refresh skipped non-dispatchable issue: #{issue_context(issue)} state=#{inspect(issue.state)}")

        state
    end
  end

  defp notify_issue_state_transition(%State{} = state, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{issue: %Issue{state: previous_state}} = running_entry ->
        maybe_notify_issue_state_transition(state, issue, previous_state, running_entry)

      _ ->
        state
    end
  end

  defp notify_issue_state_transition(%State{} = state, _issue), do: state

  defp maybe_notify_issue_state_transition(
         %State{} = state,
         %Issue{} = issue,
         previous_state,
         running_entry
       ) do
    transition_key = state_transition_key(previous_state, issue.state)

    if notify_state_transition?(previous_state, issue.state, transition_key, running_entry) do
      send_state_transition_notifications(issue, previous_state, issue.state)

      running_entry =
        Map.update(
          running_entry,
          :notified_state_transitions,
          MapSet.new([transition_key]),
          &MapSet.put(&1, transition_key)
        )

      %{state | running: Map.put(state.running, issue.id, running_entry)}
    else
      state
    end
  end

  defp notify_latest_issue_state_after_agent_completion(issue_id, running_entry)
       when is_binary(issue_id) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = latest_issue | _]} ->
        previous_state =
          running_entry
          |> Map.get(:issue)
          |> case do
            %Issue{state: state_name} -> state_name
            _ -> nil
          end

        transition_key = state_transition_key(previous_state, latest_issue.state)

        if notify_state_transition?(
             previous_state,
             latest_issue.state,
             transition_key,
             running_entry
           ) do
          send_state_transition_notifications(latest_issue, previous_state, latest_issue.state)
        end

        :ok

      {:ok, []} ->
        :ok

      {:error, reason} ->
        Logger.debug("Skipping completion notification for issue_id=#{issue_id}; state refresh failed: #{inspect(reason)}")

        :ok
    end
  end

  defp notify_latest_issue_state_after_agent_completion(_issue_id, _running_entry), do: :ok

  defp notify_state_transition?(previous_state, new_state, transition_key, running_entry) do
    normalize_issue_state(previous_state) != normalize_issue_state(new_state) and
      notifiable_state?(new_state) and
      !MapSet.member?(
        Map.get(running_entry, :notified_state_transitions, MapSet.new()),
        transition_key
      )
  end

  defp notifiable_state?(state_name) do
    Discord.notify_state?(state_name) or Cmux.notify_state?(state_name)
  end

  defp send_state_transition_notifications(%Issue{} = issue, previous_state, new_state) do
    issue
    |> Discord.send_issue_state_transition(previous_state, new_state)
    |> Discord.log_result(issue, new_state)

    issue
    |> Cmux.send_issue_state_transition(previous_state, new_state)
    |> Cmux.log_result(issue, new_state)
  end

  defp state_transition_key(previous_state, new_state) do
    {normalize_issue_state(previous_state), normalize_issue_state(new_state)}
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        state = %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

        if cleanup_workspace do
          attempt_terminal_workspace_cleanup(state, issue_id, identifier, worker_host, 1)
        else
          state
        end

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp fence_inherited_worker_tasks do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_pid(pid) ->
        SymphonyElixir.TaskSupervisor
        |> Task.Supervisor.children()
        |> Enum.each(fn child_pid ->
          Logger.warning("Fencing worker task inherited across orchestrator restart pid=#{inspect(child_pid)}")

          terminate_task(child_pid)
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      cond do
        should_prepare_pull_request_for_issue?(issue, state_acc, active_states, terminal_states) ->
          prepare_pull_request_for_issue(state_acc, issue)

        should_dispatch_issue?(issue, state_acc, active_states, terminal_states) ->
          dispatch_issue(state_acc, issue)

        true ->
          state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !planned_github_source_issue?(issue, active_states, terminal_states) and
      !human_intent_request_present?(issue) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp should_prepare_pull_request_for_issue?(
         %Issue{id: id, identifier: identifier, title: title, state: state_name, kind: :issue} =
           issue,
         %State{} = state,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    planned_github_source_issue?(issue, active_states, terminal_states) and
      issue_available_for_pull_request_preparation?(issue, state)
  end

  defp should_prepare_pull_request_for_issue?(_issue, _state, _active_states, _terminal_states),
    do: false

  defp planned_github_source_issue?(
         %Issue{state: state_name, kind: :issue} = issue,
         active_states,
         terminal_states
       ) do
    github_tracker?() and
      normalize_issue_state(state_name) == "planned" and
      issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp planned_github_source_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_available_for_pull_request_preparation?(%Issue{id: id}, %State{
         running: running,
         claimed: claimed
       }) do
    !MapSet.member?(claimed, id) and !Map.has_key?(running, id)
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name,
           kind: kind
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      Config.dispatch_kind_enabled?(kind) and
      review_state_routable?(state_name, kind) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp review_state_routable?(state_name, kind) when is_binary(state_name) do
    case normalize_issue_state(state_name) do
      "review" -> kind == :pull_request
      "reviewing" -> kind == :pull_request
      _ -> true
    end
  end

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp human_intent_request_present?(%Issue{labels: labels}) when is_list(labels) do
    request_labels =
      Config.settings!().state_manager.human_intent_labels
      |> Map.values()
      |> Enum.map(&normalize_operator_label/1)
      |> MapSet.new()

    Enum.any?(labels, &MapSet.member?(request_labels, normalize_operator_label(&1)))
  end

  defp human_intent_request_present?(_issue), do: false

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp normalize_issue_state(_state_name), do: ""

  defp github_tracker?, do: Config.settings!().tracker.kind in ["github", "forgejo"]

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case Tracker.write_ready?() do
      :ok ->
        dispatch_issue_when_ready(state, issue, attempt, preferred_worker_host)

      {:error, reason} ->
        Logger.warning("Skipping dispatch because tracker write readiness failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp dispatch_issue_when_ready(%State{} = state, issue, attempt, preferred_worker_host) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        case mark_issue_for_dispatch(refreshed_issue) do
          {:ok, dispatch_issue} ->
            do_dispatch_issue(state, dispatch_issue, attempt, preferred_worker_host)

          {:error, reason} ->
            Logger.warning("Skipping dispatch; failed to mark issue for dispatch for #{issue_context(refreshed_issue)}: #{inspect(reason)}")

            state
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp prepare_pull_request_for_issue(%State{} = state, %Issue{} = issue) do
    case Tracker.write_ready?() do
      :ok ->
        prepare_pull_request_when_ready(state, issue)

      {:error, reason} ->
        Logger.warning("Skipping pull request preparation because tracker write readiness failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp prepare_pull_request_when_ready(%State{} = state, %Issue{} = issue) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    case revalidate_issue_for_pull_request_preparation(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           state,
           active_states,
           terminal_states
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        case Tracker.create_pull_request_for_issue(refreshed_issue) do
          {:ok, %Issue{} = pull_request} ->
            Logger.info("Created or found pull request for planned issue without source worktree: #{issue_context(refreshed_issue)} pull_request=#{issue_context(pull_request)}")

            move_issue_to_human_review_after_pull_request(refreshed_issue)
            request_pull_request_refresh(pull_request)
            state

          {:error, reason} ->
            handle_pull_request_preparation_error(refreshed_issue, reason)
            state
        end

      {:skip, :missing} ->
        Logger.info("Skipping pull request preparation; issue no longer active or visible: #{issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info(
          "Skipping stale pull request preparation after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}"
        )

        state

      {:error, reason} ->
        Logger.warning("Skipping pull request preparation; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp revalidate_issue_for_pull_request_preparation(
         %Issue{id: issue_id},
         issue_fetcher,
         %State{} = state,
         active_states,
         terminal_states
       )
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if should_prepare_pull_request_for_issue?(
             refreshed_issue,
             state,
             active_states,
             terminal_states
           ) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_pull_request_preparation(
         issue,
         _issue_fetcher,
         _state,
         _active_states,
         _terminal_states
       ),
       do: {:ok, issue}

  defp move_issue_to_human_review_after_pull_request(issue, comment_body \\ nil)

  defp move_issue_to_human_review_after_pull_request(%Issue{id: issue_id} = issue, comment_body)
       when is_binary(issue_id) do
    intent = %TransitionIntent{
      id: transition_id("pr-prepared", issue_id, issue.state),
      issue_id: issue_id,
      source: :orchestrator,
      actor: "symphony",
      expected_state: issue.state,
      kind: :handoff_required,
      work_item_kind: issue.kind,
      comment_body: comment_body,
      causation_id: issue_id
    }

    case apply_dispatch_transition(intent, issue) do
      {:ok, _applied} ->
        Logger.info("Moved planned source issue to Human Review after pull request preparation: #{issue_context(issue)}")

        :ok

      other ->
        reason = if match?({:error, _}, other), do: elem(other, 1), else: other

        Logger.warning("Failed to move planned source issue to Human Review after pull request preparation for #{issue_context(issue)}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp move_issue_to_human_review_after_pull_request(_issue, _comment_body), do: :ok

  defp handle_pull_request_preparation_error(%Issue{} = issue, {provider, _parent_number})
       when provider in [:github_no_planned_sub_issue, :forgejo_no_planned_child_issue] do
    Logger.info("Moving planned parent issue with no planned sub-issue to Human Review: #{issue_context(issue)}")

    body = """
    Symphony가 이 이슈의 native sub-issue 또는 Forgejo parent-label 하위 이슈를 확인했지만 `sym:planned` 상태의 열린 하위 이슈를 찾지 못했습니다.

    부모 이슈에서는 직접 구현 PR을 만들지 않습니다. 구현할 하위 이슈에 `sym:planned`를 적용한 뒤 다시 진행해 주세요.
    """

    move_issue_to_human_review_after_pull_request(issue, body)
  end

  defp handle_pull_request_preparation_error(%Issue{} = issue, reason) do
    Logger.warning("Skipping pull request preparation for #{issue_context(issue)}: #{inspect(reason)}")
  end

  defp request_pull_request_refresh(%Issue{id: pull_request_id})
       when is_binary(pull_request_id) do
    send(self(), {:refresh_issue, pull_request_id})
    :ok
  end

  defp request_pull_request_refresh(_pull_request), do: :ok

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    case attach_worker_dispatch_context(state, issue) do
      {:ok, state, issue} ->
        dispatch_issue_with_context(state, issue, attempt, preferred_worker_host)

      {:stop, state} ->
        state
    end
  end

  defp dispatch_issue_with_context(state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp attach_worker_dispatch_context(state, issue) do
    if Config.settings!().state_manager.mode == "authoritative" do
      metadata = issue.metadata || %{}
      dispatch_id = metadata["symphony_transition_id"] || metadata[:symphony_transition_id]
      dispatch_id = dispatch_id || latest_dispatch_transition_id_for_issue(issue.id)

      if is_binary(dispatch_id) do
        {:ok, state, %{issue | metadata: Map.put(metadata, "symphony_transition_id", dispatch_id)}}
      else
        handoff_missing_dispatch_context(state, issue)
      end
    else
      {:ok, state, issue}
    end
  end

  defp handoff_missing_dispatch_context(state, issue) do
    intent = %TransitionIntent{
      id: "missing-dispatch-causation:#{issue.id}:#{issue.updated_at || issue.state}",
      issue_id: issue.id,
      source: :journal_recovery,
      actor: "symphony",
      expected_state: issue.state,
      kind: :handoff_required,
      work_item_kind: issue.kind,
      causation_id: issue.id,
      comment_body: "Symphony가 검증 가능한 dispatch causation을 찾지 못해 사람 검토로 인계합니다."
    }

    case apply_transition_intent(state, intent) do
      {{:ok, _applied}, next_state} ->
        {:stop, next_state}

      {result, next_state} ->
        _ = schedule_transition_effect_retry(result, intent.id)
        {:stop, next_state}
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case reserve_worker_dispatch(issue, attempt) do
      {:ok, dispatch_lease_id} ->
        start_reserved_worker(state, issue, attempt, recipient, worker_host, dispatch_lease_id)

      {:noop, :already_reserved} ->
        Logger.warning("Skipping duplicate durable worker dispatch for #{issue_context(issue)}")
        %{state | claimed: MapSet.put(state.claimed, issue.id)}

      {:error, reason} ->
        Logger.error("Unable to reserve worker dispatch for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp start_reserved_worker(state, issue, attempt, recipient, worker_host, dispatch_lease_id) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           run_agent_for_orchestrator(issue, recipient, attempt, worker_host)
         end) do
      {:ok, pid} ->
        _ =
          journal_record(dispatch_lease_id, :verified, %{
            issue_id: issue.id,
            worker_pid: inspect(pid)
          })

        ref = Process.monitor(pid)
        state = cancel_cleanup_retry(state, issue.id)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            notified_state_transitions: MapSet.new(),
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        _ =
          journal_record(dispatch_lease_id, :retrying, %{
            issue_id: issue.id,
            effect: :worker_dispatch,
            reason: inspect(reason)
          })

        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp reserve_worker_dispatch(issue, attempt) do
    case Config.settings!().state_manager.mode do
      "authoritative" -> reserve_authoritative_worker_dispatch(issue, attempt)
      _mode -> {:ok, "legacy-worker-dispatch"}
    end
  end

  defp reserve_authoritative_worker_dispatch(issue, attempt) do
    dispatch_lease_id = worker_dispatch_lease_id(issue, attempt)

    case journal_snapshot(dispatch_lease_id) do
      {:ok, %{phase: phase}} when phase in [:projection_applied, :verified] ->
        {:noop, :already_reserved}

      {:ok, _pending} ->
        reserve_worker_dispatch_effect(dispatch_lease_id, issue, attempt)

      :error ->
        initialize_worker_dispatch_lease(dispatch_lease_id, issue, attempt)
    end
  end

  defp worker_dispatch_lease_id(issue, attempt) do
    "worker-dispatch:#{worker_dispatch_transition_id(issue)}:attempt-#{normalize_retry_attempt(attempt)}"
  end

  defp initialize_worker_dispatch_lease(dispatch_lease_id, issue, attempt) do
    with :ok <-
           normalize_journal_record(journal_record(dispatch_lease_id, :received, %{issue_id: issue.id, attempt: attempt})),
         :ok <-
           normalize_journal_record(
             journal_record(dispatch_lease_id, :decided, %{
               issue_id: issue.id,
               effect: :worker_dispatch
             })
           ) do
      reserve_worker_dispatch_effect(dispatch_lease_id, issue, attempt)
    end
  end

  defp reserve_worker_dispatch_effect(dispatch_lease_id, issue, attempt) do
    result =
      journal_record(dispatch_lease_id, :projection_applied, %{
        issue_id: issue.id,
        effect: :worker_dispatch,
        attempt: attempt,
        reserved_at: System.system_time(:millisecond)
      })

    case normalize_journal_record(result) do
      :ok -> {:ok, dispatch_lease_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp worker_dispatch_transition_id(issue) do
    metadata = issue.metadata || %{}

    metadata["symphony_transition_id"] || metadata[:symphony_transition_id] ||
      latest_dispatch_transition_id(issue) || dispatch_transition_id(issue)
  end

  defp latest_dispatch_transition_id(issue) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) ->
        pid
        |> TransitionJournal.replay()
        |> Enum.reverse()
        |> Enum.find_value(&matching_dispatch_transition_id(&1, issue))

      _ ->
        nil
    end
  end

  defp matching_dispatch_transition_id(event, issue) do
    if event.phase == :verified and event.data[:issue_id] == issue.id and
         event.data[:to_state] == issue.state and
         event.data[:kind] in [
           :dispatch_planning,
           :dispatch_implementation,
           :dispatch_review,
           :dispatch_rework
         ] do
      event.transition_id
    end
  end

  defp run_agent_for_orchestrator(issue, recipient, attempt, worker_host) do
    case AgentRunner.run(issue, recipient,
           attempt: attempt,
           worker_host: worker_host,
           raise_on_error: false
         ) do
      :ok -> :ok
      {:error, reason} -> send(recipient, {:agent_run_failed, issue.id, reason})
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp mark_issue_for_dispatch(%Issue{state: state_name} = issue) do
    case dispatch_intent_kind(state_name) do
      nil -> {:ok, issue}
      intent_kind -> dispatch_marked_issue(issue, intent_kind)
    end
  end

  defp dispatch_intent_kind(state_name) do
    case normalize_issue_state(state_name) do
      "todo" -> :dispatch_planning
      "planned" -> :dispatch_implementation
      "rework" -> :dispatch_rework
      "review" -> :dispatch_review
      _ -> nil
    end
  end

  defp dispatch_marked_issue(%Issue{} = issue, :dispatch_planning) do
    if Config.settings!().state_manager.mode in ["shadow", "authoritative"] do
      record_planning_dispatch_receipt(issue)
    else
      {:ok, issue}
    end
  end

  defp dispatch_marked_issue(%Issue{state: state_name} = issue, intent_kind) do
    intent = %TransitionIntent{
      id: dispatch_transition_id(issue),
      issue_id: issue.id,
      source: :dispatch,
      actor: "symphony",
      expected_state: state_name,
      kind: intent_kind,
      work_item_kind: issue.kind,
      head_oid: issue.metadata && (issue.metadata["head_oid"] || issue.metadata[:head_oid]),
      causation_id: issue.id
    }

    case apply_dispatch_transition(intent, issue) do
      {:ok, %AppliedTransition{to_state: target_state}} ->
        Logger.info("Marked issue for dispatch: #{issue_context(issue)} previous_state=#{inspect(state_name)} state=#{target_state}")

        metadata =
          issue.metadata
          |> Kernel.||(%{})
          |> Map.put("symphony_dispatch_state", state_name)
          |> Map.put("symphony_transition_id", intent.id)

        {:ok, %{issue | state: target_state, metadata: metadata}}

      {:noop, :already_applied} ->
        {:ok, issue}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:dispatch_transition_failed, other}}
    end
  end

  defp record_planning_dispatch_receipt(%Issue{state: state_name} = issue) do
    transition_id = dispatch_transition_id(issue)

    data = %{
      issue_id: issue.id,
      source: :dispatch,
      actor: "symphony",
      from_state: state_name,
      to_state: state_name,
      kind: :dispatch_planning,
      causation_id: issue.id,
      work_item_kind: issue.kind,
      head_oid: issue.metadata && (issue.metadata["head_oid"] || issue.metadata[:head_oid]),
      effect: :dispatch_receipt
    }

    with :ok <- ensure_planning_dispatch_receipt(transition_id, data) do
      Logger.info("Recorded planning dispatch receipt: #{issue_context(issue)} state=#{state_name}")

      metadata =
        issue.metadata
        |> Kernel.||(%{})
        |> Map.put("symphony_dispatch_state", state_name)
        |> Map.put("symphony_transition_id", transition_id)

      {:ok, %{issue | metadata: metadata}}
    end
  end

  defp ensure_planning_dispatch_receipt(transition_id, data) do
    case journal_snapshot(transition_id) do
      {:ok, %{phase: :verified, data: %{issue_id: issue_id, kind: :dispatch_planning}}}
      when issue_id == data.issue_id ->
        :ok

      {:ok, %{phase: :verified}} ->
        {:error, {:dispatch_receipt_collision, transition_id}}

      {:ok, snapshot} ->
        complete_planning_dispatch_receipt(transition_id, snapshot.phase, data)

      :error ->
        with :ok <- normalize_journal_record(journal_record(transition_id, :received, data)) do
          complete_planning_dispatch_receipt(transition_id, :received, data)
        end
    end
  end

  defp complete_planning_dispatch_receipt(transition_id, :received, data) do
    with :ok <- normalize_journal_record(journal_record(transition_id, :decided, data)) do
      complete_planning_dispatch_receipt(transition_id, :decided, data)
    end
  end

  defp complete_planning_dispatch_receipt(transition_id, :retrying, data) do
    with :ok <- normalize_journal_record(journal_record(transition_id, :decided, data)) do
      complete_planning_dispatch_receipt(transition_id, :decided, data)
    end
  end

  defp complete_planning_dispatch_receipt(transition_id, :decided, data),
    do: normalize_journal_record(journal_record(transition_id, :verified, data))

  defp complete_planning_dispatch_receipt(_transition_id, :verified, _data), do: :ok

  defp complete_planning_dispatch_receipt(_transition_id, phase, _data),
    do: {:error, {:invalid_dispatch_receipt_phase, phase}}

  defp dispatch_transition_id(%Issue{} = issue) do
    revision =
      issue.updated_at ||
        (issue.metadata && (issue.metadata["head_oid"] || issue.metadata[:head_oid])) ||
        issue.state

    transition_id("dispatch", issue.id, "#{issue.state}:#{revision}")
  end

  defp apply_dispatch_transition(intent, current_issue) do
    mode = Config.settings!().state_manager.mode

    transition_result =
      case ensure_transition_received(intent, mode) do
        :ok -> apply_transition_intent_from_issue(%State{}, mode, intent, current_issue)
        {:noop, reason} -> {{:noop, reason}, %State{}}
        {:error, reason} -> {{:error, reason}, %State{}}
      end

    case transition_result do
      {result, _state} ->
        result
    end
  end

  defp transition_id(prefix, issue_id, state_name) do
    normalized_state =
      state_name |> to_string() |> normalize_issue_state() |> String.replace(" ", "-")

    "#{prefix}:#{issue_id}:#{normalized_state}"
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1

    if Config.settings!().state_manager.mode == "authoritative" and
         next_attempt > @max_failure_retry_attempts do
      handoff_exhausted_retry(state, issue_id, next_attempt, metadata)
    else
      schedule_retry_timer(state, issue_id, next_attempt, previous_retry, metadata)
    end
  end

  defp schedule_retry_timer(state, issue_id, next_attempt, previous_retry, metadata) do
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp handoff_exhausted_retry(state, issue_id, attempt, metadata) do
    intent = %TransitionIntent{
      id: "retry-exhausted:#{issue_id}:#{attempt}",
      issue_id: issue_id,
      source: :retry_budget,
      actor: "symphony",
      kind: :handoff_required,
      causation_id: issue_id,
      comment_body:
        "Symphony 자동 재시도 한도를 소진하여 사람 검토로 인계합니다.\n\n" <>
          "- 시도 횟수: #{attempt - 1}\n- 마지막 오류: #{metadata[:error] || "알 수 없음"}"
    }

    case apply_transition_intent(state, intent) do
      {{:ok, _applied}, next_state} ->
        Logger.warning("Retry budget exhausted; handed off issue_id=#{issue_id} attempts=#{attempt - 1}")

        %{next_state | retry_attempts: Map.delete(next_state.retry_attempts, issue_id)}

      {result, next_state} ->
        _ = schedule_transition_effect_retry(result, intent.id)

        Logger.error("Retry budget exhausted but handoff failed issue_id=#{issue_id} result=#{inspect(result)}")

        %{next_state | retry_attempts: Map.delete(next_state.retry_attempts, issue_id)}
    end
  end

  defp handoff_exhausted_transition_effect(state, transition_id, reason) do
    case journal_snapshot(transition_id) do
      {:ok, snapshot} ->
        issue_id = snapshot.data[:issue_id]

        intent = %TransitionIntent{
          id: "effect-retry-exhausted:#{transition_id}",
          issue_id: issue_id,
          source: :effect_retry_budget,
          actor: "symphony",
          kind: :handoff_required,
          causation_id: transition_id,
          comment_body:
            "Symphony 상태 효과 재시도 한도를 소진하여 사람 검토로 인계합니다.\n\n" <>
              "- 전이 ID: #{transition_id}\n- 마지막 오류: #{inspect(reason)}"
        }

        _ =
          journal_record(transition_id, :retrying, %{
            issue_id: issue_id,
            handoff_transition_id: intent.id,
            reason: inspect(reason)
          })

        case apply_transition_intent(state, intent) do
          {{:ok, _applied}, next_state} ->
            _ =
              journal_record(transition_id, :verified, %{
                issue_id: issue_id,
                abandoned_effect: true,
                handoff_transition_id: intent.id,
                reason: inspect(reason)
              })

            next_state

          {handoff_result, next_state} ->
            _ = schedule_transition_effect_retry(handoff_result, intent.id)

            Logger.error("Transition effect handoff failed transition_id=#{transition_id} result=#{inspect(handoff_result)}")

            next_state
        end

      :error ->
        Logger.error("Transition effect handoff lacks journal snapshot transition_id=#{transition_id}")

        state
    end
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        state =
          state
          |> attempt_terminal_workspace_cleanup(
            issue_id,
            issue.identifier,
            metadata[:worker_host],
            1
          )
          |> release_issue_claim(issue_id)

        {:noreply, state}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp attempt_terminal_workspace_cleanup(
         %State{} = state,
         issue_id,
         identifier,
         worker_host,
         retry_attempt
       )
       when is_binary(issue_id) and is_binary(identifier) do
    state = cancel_cleanup_retry(state, issue_id)

    case cleanup_issue_workspace(identifier, worker_host) do
      :ok ->
        Logger.info("Removed terminal issue workspace issue_id=#{issue_id} issue_identifier=#{identifier} worker_host=#{worker_host_for_log(worker_host)}")

        state

      {:error, reason} ->
        schedule_cleanup_retry(state, issue_id, retry_attempt, %{
          identifier: identifier,
          worker_host: worker_host,
          error: reason
        })
    end
  end

  defp attempt_terminal_workspace_cleanup(
         state,
         _issue_id,
         _identifier,
         _worker_host,
         _retry_attempt
       ),
       do: state

  defp schedule_cleanup_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and is_map(metadata) do
    previous_retry = Map.get(state.cleanup_retries, issue_id, %{})
    old_timer = Map.get(previous_retry, :timer_ref)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    delay_ms = failure_retry_delay(attempt)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    timer_ref = Process.send_after(self(), {:retry_cleanup, issue_id, retry_token}, delay_ms)
    identifier = Map.fetch!(metadata, :identifier)
    worker_host = Map.get(metadata, :worker_host)
    error = Map.get(metadata, :error)

    Logger.warning(
      "Retrying terminal workspace cleanup issue_id=#{issue_id} issue_identifier=#{identifier} worker_host=#{worker_host_for_log(worker_host)} in #{delay_ms}ms (attempt #{attempt}) error=#{inspect(error)}"
    )

    retry_entry = %{
      attempt: attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: due_at_ms,
      identifier: identifier,
      worker_host: worker_host,
      error: error
    }

    %{state | cleanup_retries: Map.put(state.cleanup_retries, issue_id, retry_entry)}
  end

  defp pop_cleanup_retry_state(%State{} = state, issue_id, retry_token) do
    case Map.get(state.cleanup_retries, issue_id) do
      %{retry_token: ^retry_token} = retry_entry ->
        {:ok, retry_entry, %{state | cleanup_retries: Map.delete(state.cleanup_retries, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_cleanup_retry(%State{} = state, issue_id, retry_entry) do
    identifier = retry_entry.identifier
    worker_host = retry_entry.worker_host
    next_attempt = retry_entry.attempt + 1

    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        if terminal_issue_state?(issue.state, terminal_state_set()) do
          handle_terminal_cleanup_retry(state, issue_id, identifier, worker_host, next_attempt)
        else
          Logger.info("Canceled terminal workspace cleanup retry because issue is no longer terminal issue_id=#{issue_id} issue_identifier=#{identifier} state=#{inspect(issue.state)}")

          state
        end

      {:ok, []} ->
        schedule_cleanup_retry(state, issue_id, next_attempt, %{
          identifier: identifier,
          worker_host: worker_host,
          error: :tracker_issue_not_visible
        })

      {:error, reason} ->
        schedule_cleanup_retry(state, issue_id, next_attempt, %{
          identifier: identifier,
          worker_host: worker_host,
          error: {:tracker_fetch_failed, reason}
        })
    end
  end

  defp handle_terminal_cleanup_retry(state, issue_id, identifier, worker_host, next_attempt) do
    if Map.has_key?(state.running, issue_id) do
      terminate_running_issue(state, issue_id, true)
    else
      attempt_terminal_workspace_cleanup(state, issue_id, identifier, worker_host, next_attempt)
    end
  end

  defp cancel_cleanup_retry(%State{} = state, issue_id) do
    case Map.pop(state.cleanup_retries, issue_id) do
      {nil, _cleanup_retries} ->
        state

      {%{timer_ref: timer_ref}, cleanup_retries} ->
        if is_reference(timer_ref) do
          Process.cancel_timer(timer_ref)
        end

        %{state | cleanup_retries: cleanup_retries}
    end
  end

  defp run_terminal_workspace_cleanup(%State{} = state) do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        Enum.reduce(issues, state, fn
          %Issue{id: issue_id, identifier: identifier}, state_acc
          when is_binary(issue_id) and is_binary(identifier) ->
            attempt_terminal_workspace_cleanup(state_acc, issue_id, identifier, nil, 1)

          _issue, state_acc ->
            state_acc
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")

        state
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec request_issue_refresh(GenServer.server(), String.t()) :: map() | :unavailable
  def request_issue_refresh(server, issue_id) when is_binary(issue_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:request_issue_refresh, issue_id})
    else
      :unavailable
    end
  end

  @spec request_tracker_intent(map(), GenServer.server()) ::
          SymphonyElixir.StateManager.result() | :unavailable
  def request_tracker_intent(intent, server \\ __MODULE__) when is_map(intent) do
    case Map.get(intent, :kind) || Map.get(intent, "kind") do
      :projection_echo ->
        record_refresh_only_tracker_intent(intent, :projection_echo)

      :state_projection_drift ->
        safe_orchestrator_call(server, {:projection_drift, intent})

      kind when kind in [:head_updated, :review_submitted] ->
        record_refresh_only_tracker_intent(intent, kind)

      _ ->
        with {:ok, transition_intent} <- transition_intent_from_tracker_event(intent) do
          try do
            SymphonyElixir.StateManager.request(server, transition_intent)
          catch
            :exit, _reason -> :unavailable
          end
        end
    end
  end

  # Refresh-only tracker facts still need a durable receipt.  Otherwise a
  # replayed signed webhook can repeatedly queue targeted refreshes despite
  # having no state transition to deduplicate through StateManager.
  defp record_refresh_only_tracker_intent(intent, kind) do
    id = intent_id(intent)
    digest = payload_digest(intent)

    data = %{
      issue_id: intent_value(intent, :issue_id),
      source: tracker_event_source(intent),
      kind: kind,
      payload_digest: digest,
      refresh_only: true
    }

    case journal_snapshot(id) do
      {:ok, %{phase: :verified, data: %{payload_digest: ^digest}}} ->
        {:noop, :already_applied}

      {:ok,
       %{
         phase: phase,
         data: %{payload_digest: ^digest, refresh_only: true}
       }} ->
        with :ok <- complete_refresh_only_receipt(id, phase, data) do
          {:noop, kind}
        end

      {:ok, %{data: %{payload_digest: existing}}} when is_binary(existing) ->
        {:error, {:tracker_delivery_payload_mismatch, id}}

      {:ok, _pending} ->
        {:error, {:tracker_delivery_in_progress, id}}

      :error ->
        with :ok <- normalize_journal_record(journal_record(id, :received, data)),
             :ok <- complete_refresh_only_receipt(id, :received, data) do
          {:noop, kind}
        end
    end
  end

  defp complete_refresh_only_receipt(id, phase, data) when phase in [:received, :retrying] do
    with :ok <- normalize_journal_record(journal_record(id, :decided, data)) do
      complete_refresh_only_receipt(id, :decided, data)
    end
  end

  defp complete_refresh_only_receipt(id, :decided, data),
    do: normalize_journal_record(journal_record(id, :verified, data))

  defp complete_refresh_only_receipt(_id, :verified, _data), do: :ok

  defp complete_refresh_only_receipt(_id, phase, _data),
    do: {:error, {:invalid_refresh_only_receipt_phase, phase}}

  @spec request_refresh_after(GenServer.server(), non_neg_integer()) :: :ok | :unavailable
  def request_refresh_after(server, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        Process.send_after(pid, :tick, delay_ms)
        :ok

      _ ->
        :unavailable
    end
  end

  @spec request_issue_refresh_after(GenServer.server(), String.t(), non_neg_integer()) ::
          :ok | :unavailable
  def request_issue_refresh_after(server, issue_id, delay_ms)
      when is_binary(issue_id) and is_integer(delay_ms) and delay_ms >= 0 do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        Process.send_after(pid, {:refresh_issue, issue_id}, delay_ms)
        :ok

      _ ->
        :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:transition_request, %TransitionIntent{} = intent}, _from, state) do
    {result, state} = apply_transition_intent(state, intent)
    result = schedule_transition_effect_retry(result, intent.id)
    notify_dashboard()
    {:reply, result, state}
  end

  def handle_call({:projection_drift, intent}, _from, state) when is_map(intent) do
    {result, state} = reconcile_projection_drift(state, intent)
    {:reply, result, state}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       state_manager: state_manager_snapshot(state),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:request_issue_refresh, issue_id}, _from, state) when is_binary(issue_id) do
    send(self(), {:refresh_issue, issue_id})

    {:reply,
     %{
       queued: true,
       coalesced: Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id),
       requested_at: DateTime.utc_now(),
       operations: ["targeted-reconcile"],
       issue_id: issue_id
     }, state}
  end

  defp apply_transition_intent(%State{} = state, %TransitionIntent{} = intent) do
    mode = Config.settings!().state_manager.mode

    case ensure_transition_received(intent, mode) do
      :ok -> fetch_and_apply_transition_intent(state, mode, intent)
      {:noop, reason} -> {{:noop, reason}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp schedule_transition_effect_retry({:error, reason}, transition_id) do
    Process.send_after(
      self(),
      {:retry_transition_effect, transition_id, 1},
      @transition_effect_retry_ms
    )

    {:error, {:transition_retry_scheduled, reason}}
  end

  defp schedule_transition_effect_retry(result, _transition_id), do: result

  defp fetch_and_apply_transition_intent(state, mode, intent) do
    case fetch_transition_issue(intent.issue_id) do
      {:ok, current_issue} ->
        apply_transition_intent_from_issue(state, mode, intent, current_issue)

      {:error, reason} ->
        maybe_quarantine_unreadable_intent(state, mode, intent, reason)
    end
  end

  defp maybe_quarantine_unreadable_intent(
         state,
         "authoritative",
         %TransitionIntent{
           source: source,
           kind: {:operator_request, :rework},
           metadata: %{kind: :review_feedback_detected}
         } = intent,
         :missing_canonical_state
       )
       when source in [:github_webhook, :forgejo_webhook] do
    finalize_non_effect_decision(
      state,
      "authoritative",
      intent,
      :noop,
      :untracked_review_feedback
    )
  end

  defp maybe_quarantine_unreadable_intent(
         state,
         "authoritative",
         %TransitionIntent{kind: {:operator_request, _}} = intent,
         reason
       ) do
    case quarantine_unreadable_operator_request(intent, reason) do
      result when result in [:applied, :already_applied] ->
        finalize_quarantined_operator_intent(state, intent, reason, result)

      {:error, effect_reason} ->
        {{:error, {:quarantine_failed, effect_reason}}, state}
    end
  end

  defp maybe_quarantine_unreadable_intent(state, _mode, _intent, reason),
    do: {{:error, reason}, state}

  defp finalize_quarantined_operator_intent(state, intent, reason, result) do
    data = %{
      issue_id: intent.issue_id,
      mode: "authoritative",
      result: :rejected,
      reason: inspect({:quarantined, reason}),
      quarantine_status: result
    }

    with :ok <- normalize_journal_record(journal_record(intent.id, :decided, data)),
         :ok <-
           normalize_journal_record(journal_record(intent.id, :required_comment_applied, data)),
         :ok <- normalize_journal_record(journal_record(intent.id, :projection_applied, data)),
         :ok <- normalize_journal_record(journal_record(intent.id, :verified, data)) do
      {{:rejected, {:quarantined, reason}}, state}
    else
      {:error, journal_reason} -> {{:error, journal_reason}, state}
    end
  end

  defp apply_transition_intent_from_issue(state, mode, intent, current_issue) do
    with :ok <- validate_worker_causation(intent, current_issue),
         :ok <- validate_operator_request_labels(mode, intent, current_issue) do
      intent =
        if is_nil(intent.expected_state),
          do: %{intent | expected_state: current_issue.state},
          else: intent

      decision = WorkflowStatePolicy.decide(current_issue.state, intent)
      apply_transition_decision(state, mode, intent, decision)
    else
      {:noop, reason} ->
        finalize_non_effect_decision(state, mode, intent, :noop, reason)

      {:rejected, reason} ->
        reconciliation_result(state, intent, reason)
    end
  end

  defp validate_worker_causation(
         %TransitionIntent{source: :worker, metadata: %{dispatch_transition_id: dispatch_id}} =
           intent,
         current_issue
       )
       when is_binary(dispatch_id) and dispatch_id != "" do
    latest_dispatch_id = latest_dispatch_transition_id_for_issue(intent.issue_id)

    live_head_oid =
      current_issue.metadata &&
        (current_issue.metadata["head_oid"] || current_issue.metadata[:head_oid])

    cond do
      latest_dispatch_id != dispatch_id ->
        {:noop, :stale_causation}

      missing_required_pull_request_head?(current_issue, live_head_oid, intent.head_oid) ->
        {:noop, :missing_head_oid}

      stale_head_oid?(intent.head_oid, live_head_oid) ->
        {:noop, :stale_head_oid}

      true ->
        :ok
    end
  end

  defp validate_worker_causation(%TransitionIntent{source: :worker}, _current_issue),
    do: {:noop, :missing_causation}

  defp validate_worker_causation(_intent, _current_issue), do: :ok

  defp missing_required_pull_request_head?(current_issue, live_head_oid, outcome_head_oid) do
    current_issue.kind == :pull_request and nonempty_binary?(live_head_oid) and
      not nonempty_binary?(outcome_head_oid)
  end

  defp stale_head_oid?(outcome_head_oid, live_head_oid) do
    is_binary(outcome_head_oid) and is_binary(live_head_oid) and outcome_head_oid != live_head_oid
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp latest_dispatch_transition_id_for_issue(issue_id) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) ->
        pid
        |> TransitionJournal.replay()
        |> Enum.reverse()
        |> Enum.find_value(&dispatch_transition_id(&1, issue_id))

      _ ->
        nil
    end
  end

  defp dispatch_transition_id(event, issue_id) do
    dispatch_kind? =
      event.data[:kind] in [
        :dispatch_planning,
        :dispatch_implementation,
        :dispatch_review,
        :dispatch_rework
      ]

    if event.phase == :verified and event.data[:issue_id] == issue_id and dispatch_kind?,
      do: event.transition_id
  end

  defp validate_operator_request_labels(
         "authoritative",
         %TransitionIntent{
           source: source,
           kind: {:operator_request, _},
           metadata: %{kind: :operator_transition_requested}
         } = intent,
         issue
       )
       when source in [:github_webhook, :forgejo_webhook] do
    request_labels =
      Config.settings!().state_manager.human_intent_labels
      |> Map.values()
      |> Enum.map(&normalize_operator_label/1)
      |> MapSet.new()

    observed =
      (issue.labels || [])
      |> Enum.filter(&MapSet.member?(request_labels, normalize_operator_label(&1)))

    expected_label = intent.metadata[:label] |> normalize_operator_label()

    case observed do
      [label] ->
        if normalize_operator_label(label) == expected_label,
          do: :ok,
          else: {:rejected, {:request_label_mismatch, expected_label, label}}

      [] ->
        stale_request_delivery_or_rejection(issue, expected_label)

      labels ->
        {:rejected, {:ambiguous_request_labels, expected_label, Enum.sort(labels)}}
    end
  end

  defp validate_operator_request_labels(_mode, _intent, _issue), do: :ok

  defp normalize_operator_label(label) when is_binary(label),
    do: label |> String.trim() |> String.downcase()

  defp normalize_operator_label(_label), do: ""

  defp quarantine_unreadable_operator_request(intent, reason) do
    marker = "<!-- sym-transition:#{intent.id}:quarantine -->"

    body =
      "Symphony가 상태 요청을 격리했습니다. 검증 가능한 상태 라벨이 정확히 하나가 아니므로 작업을 실행하지 않습니다.\n\n" <>
        "- 사유: #{inspect(reason)}"

    with comment_result when comment_result in [:applied, :already_applied] <-
           Tracker.create_comment_once(intent.issue_id, body, marker) do
      restore_quarantined_projection(intent.issue_id, comment_result)
    end
  end

  defp restore_quarantined_projection(issue_id, comment_result) do
    case committed_state_for_issue(issue_id) do
      {:ok, committed_state} ->
        case Tracker.apply_state_projection(issue_id, :any, committed_state) do
          projection when elem(projection, 0) in [:applied, :already_applied] ->
            comment_result

          {:conflict, snapshot} ->
            {:error, {:quarantine_projection_conflict, snapshot}}

          {:partial_failure, details} ->
            {:error, {:quarantine_projection_partial_failure, details}}
        end

      :error ->
        comment_result
    end
  end

  defp stale_request_delivery_or_rejection(issue, expected_label) do
    case committed_state_for_issue(issue.id) do
      {:ok, committed_state} when committed_state == issue.state ->
        {:noop, :stale_request_delivery}

      _ ->
        {:rejected, {:missing_request_label, expected_label}}
    end
  end

  defp apply_transition_decision(state, mode, intent, {:noop, reason}),
    do: finalize_non_effect_decision(state, mode, intent, :noop, reason)

  defp apply_transition_decision(state, mode, intent, {:conflict, snapshot}) do
    state = %{state | transition_conflicts: state.transition_conflicts + 1}
    finalize_non_effect_decision(state, mode, intent, :conflict, snapshot)
  end

  defp apply_transition_decision(
         state,
         "authoritative",
         %TransitionIntent{kind: {:operator_request, _}} = intent,
         {:rejected, reason}
       ) do
    reconciliation_result(state, intent, reason)
  end

  defp apply_transition_decision(state, mode, intent, {:rejected, reason}),
    do: finalize_non_effect_decision(state, mode, intent, :rejected, reason)

  defp apply_transition_decision(state, "shadow", _intent, {:ok, plan}),
    do: apply_shadow_plan(state, plan, true)

  defp apply_transition_decision(state, "legacy", _intent, {:ok, plan}) do
    with :ok <- apply_legacy_transition_comment(plan),
         :ok <- Tracker.adapter().update_issue_state(plan.issue_id, plan.to_state) do
      applied = AppliedTransition.from_plan(plan, metadata: %{mode: "legacy"})
      {{:ok, applied}, %{state | last_transition: applied}}
    else
      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp apply_transition_decision(state, "authoritative", _intent, {:ok, plan}) do
    apply_authoritative_plan(state, plan, true)
  end

  defp apply_transition_decision(state, mode, _intent, {:ok, _plan}),
    do: {{:error, {:unsupported_state_manager_mode, mode}}, state}

  defp apply_shadow_plan(state, plan, record_decision?) do
    with :ok <- maybe_record_shadow_decision(plan, record_decision?),
         :ok <- apply_shadow_legacy_comment(plan),
         :ok <- apply_shadow_legacy_projection(plan),
         {:ok, readback} <- verify_shadow_projection(plan),
         :ok <-
           normalize_journal_record(
             journal_record(
               plan.id,
               :verified,
               transition_plan_data(plan, %{mode: "shadow", shadow_readback: readback})
             )
           ) do
      applied =
        AppliedTransition.from_plan(plan, metadata: %{mode: "shadow", shadow_readback: readback})

      {{:ok, applied}, %{state | last_transition: applied}}
    else
      {:error, reason} ->
        _ = journal_retry(plan, reason, %{mode: "shadow"})
        {{:error, reason}, state}
    end
  end

  defp maybe_record_shadow_decision(plan, true) do
    normalize_journal_record(journal_record(plan.id, :decided, transition_plan_data(plan, %{mode: "shadow"})))
  end

  defp maybe_record_shadow_decision(_plan, false), do: :ok

  defp apply_shadow_legacy_projection(plan) do
    if journal_phase_reached?(plan.id, :projection_applied) do
      :ok
    else
      with :ok <- Tracker.write_ready?() do
        Tracker.adapter().update_issue_state(plan.issue_id, plan.to_state)
      end
    end
  end

  defp apply_shadow_legacy_comment(%{comment_body: body} = plan)
       when is_binary(body) and body != "" do
    if journal_phase_reached?(plan.id, :required_comment_applied) do
      :ok
    else
      with :ok <- apply_legacy_transition_comment(plan) do
        normalize_journal_record(
          journal_record(plan.id, :required_comment_applied, %{
            mode: "shadow",
            legacy_comment: true
          })
        )
      end
    end
  end

  defp apply_shadow_legacy_comment(_plan), do: :ok

  defp verify_shadow_projection(plan) do
    case fetch_transition_issue(plan.issue_id) do
      {:ok, %{state: state}} when state == plan.to_state ->
        with :ok <-
               normalize_journal_record(
                 journal_record(plan.id, :projection_applied, %{
                   mode: "shadow",
                   agreement: true,
                   state: state
                 })
               ) do
          {:ok, %{agreement: true, state: state}}
        end

      {:ok, issue} ->
        mismatch = %{
          mode: "shadow",
          agreement: false,
          expected_state: plan.to_state,
          state: issue.state
        }

        with :ok <-
               normalize_journal_record(journal_record(plan.id, :projection_applied, mismatch)),
             :ok <- normalize_journal_record(journal_record(plan.id, :verified, mismatch)) do
          {:error, {:shadow_policy_mismatch, plan.to_state, issue.state}}
        end

      {:error, reason} ->
        {:error, {:shadow_readback_failed, reason}}
    end
  end

  defp reconciliation_result(state, intent, reason) do
    with :ok <- record_non_effect_decision(intent, "authoritative", :rejected, reason),
         :ok <- reconcile_rejected_operator_intent(intent, reason),
         :ok <- record_verified_decision(intent, "authoritative", :rejected, reason) do
      {{:rejected, reason}, state}
    else
      {:error, effect_reason} ->
        _ = journal_retry_for_intent(intent, {:reconciliation_failed, effect_reason})
        {{:error, {:reconciliation_failed, effect_reason}}, state}
    end
  end

  defp finalize_non_effect_decision(state, mode, intent, result, reason)
       when mode in ["shadow", "authoritative"] do
    with :ok <- record_non_effect_decision(intent, mode, result, reason),
         :ok <- record_verified_decision(intent, mode, result, reason) do
      {decision_result(result, reason), state}
    else
      {:error, journal_reason} -> {{:error, journal_reason}, state}
    end
  end

  defp finalize_non_effect_decision(state, _mode, _intent, result, reason),
    do: {decision_result(result, reason), state}

  defp decision_result(:noop, reason), do: {:noop, reason}
  defp decision_result(:conflict, snapshot), do: {:conflict, snapshot}
  defp decision_result(:rejected, reason), do: {:rejected, reason}

  defp record_non_effect_decision(intent, mode, result, reason) do
    normalize_journal_record(
      journal_record(intent.id, :decided, %{
        issue_id: intent.issue_id,
        mode: mode,
        result: result,
        reason: inspect(reason)
      })
    )
  end

  defp record_verified_decision(intent, mode, result, reason) do
    normalize_journal_record(
      journal_record(intent.id, :verified, %{
        issue_id: intent.issue_id,
        mode: mode,
        result: result,
        reason: inspect(reason)
      })
    )
  end

  defp apply_authoritative_plan(state, plan, record_decision?) do
    with :ok <- maybe_record_transition_decision(plan, record_decision?),
         :ok <- apply_required_transition_comment(plan),
         :ok <- apply_transition_broker_effects(plan),
         {:ok, projection_metadata} <- apply_tracker_projection(plan),
         {:ok, next_state} <- maybe_complete_forgejo_parent(state, plan),
         :ok <-
           normalize_journal_record(
             journal_record(
               plan.id,
               :verified,
               Map.put(transition_plan_data(plan), :projection, projection_metadata)
             )
           ) do
      applied = AppliedTransition.from_plan(plan, metadata: %{projection: projection_metadata})
      {{:ok, applied}, %{next_state | last_transition: applied}}
    else
      {:deferred, handoff_metadata} ->
        finalize_deferred_parent_completion(state, plan, handoff_metadata)

      {:conflict, snapshot} ->
        _ = journal_retry(plan, {:conflict, snapshot})
        {{:conflict, snapshot}, %{state | transition_conflicts: state.transition_conflicts + 1}}

      {:error, reason} ->
        _ = journal_retry(plan, reason)
        {{:error, reason}, state}
    end
  end

  defp finalize_deferred_parent_completion(state, plan, handoff_metadata) do
    case normalize_journal_record(
           journal_record(
             plan.id,
             :verified,
             transition_plan_data(plan, %{parent_completion_handoff: handoff_metadata})
           )
         ) do
      :ok ->
        # The requested terminal projection was intentionally superseded by
        # the journaled Human Review handoff. Treating it as a retry would
        # replay an obsolete Done plan after the parent already moved.
        {{:noop, {:parent_completion_deferred, handoff_metadata.transition_id}}, state}

      {:error, reason} ->
        _ = journal_retry(plan, reason)
        {{:error, reason}, state}
    end
  end

  defp maybe_record_transition_decision(plan, true),
    do: normalize_journal_record(journal_record(plan.id, :decided, transition_plan_data(plan)))

  defp maybe_record_transition_decision(_plan, false), do: :ok

  defp apply_legacy_transition_comment(%{comment_body: body, issue_id: issue_id})
       when is_binary(body) and body != "",
       do: Tracker.create_comment(issue_id, body)

  defp apply_legacy_transition_comment(_plan), do: :ok

  defp ensure_transition_received(%TransitionIntent{} = intent, mode)
       when mode in ["shadow", "authoritative"] do
    case journal_snapshot(intent.id) do
      {:ok, %{phase: :verified}} ->
        {:noop, :already_applied}

      {:ok, _pending} ->
        :ok

      :error ->
        normalize_journal_record(journal_record(intent.id, :received, transition_intent_data(intent)))
    end
  end

  defp ensure_transition_received(_intent, _mode), do: :ok

  defp fetch_transition_issue(issue_id) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :transition_issue_not_found}
      {:error, :missing_canonical_state} -> {:error, :missing_canonical_state}
      {:error, reason} -> {:error, {:transition_issue_fetch_failed, reason}}
    end
  end

  defp apply_required_transition_comment(%{comment_body: body} = plan)
       when is_binary(body) and body != "" do
    if journal_phase_reached?(plan.id, :required_comment_applied) do
      :ok
    else
      marker = "<!-- sym-transition:#{plan.id} -->"

      case Tracker.create_comment_once(plan.issue_id, body, marker) do
        result when result in [:applied, :already_applied] ->
          normalize_journal_record(
            journal_record(plan.id, :required_comment_applied, %{
              comment_marker: marker,
              comment_status: result
            })
          )

        {:error, reason} ->
          {:error, {:transition_comment_failed, reason}}
      end
    end
  end

  defp apply_required_transition_comment(_plan), do: :ok

  defp apply_transition_broker_effects(%{kind: :merge_ready, head_oid: head_oid} = plan)
       when is_binary(head_oid) and head_oid != "" do
    case Tracker.merge_pull_request(plan.issue_id, head_oid) do
      {:applied, _metadata} -> :ok
      {:conflict, snapshot} -> {:conflict, snapshot}
      {:error, reason} -> {:error, {:merge_failed, reason}}
    end
  end

  defp apply_transition_broker_effects(%{kind: :merge_ready}),
    do: {:error, :merge_head_oid_required}

  defp apply_transition_broker_effects(_plan), do: :ok

  defp reconcile_rejected_operator_intent(intent, reason) do
    with {:ok, issue} <- fetch_transition_issue(intent.issue_id) do
      marker = rejected_request_marker(intent, issue, reason)

      body =
        "Symphony가 요청한 상태 전이를 적용하지 않았습니다.\n\n" <>
          "- 현재 상태: #{issue.state}\n- 사유: #{inspect(reason)}"

      with :ok <- apply_rejection_comment_once(intent, body, marker),
           :ok <- apply_rejection_projection_once(intent, issue.state) do
        :ok
      else
        {:error, effect_reason} -> {:error, effect_reason}
      end
    end
  end

  defp apply_rejection_comment_once(intent, body, marker) do
    if journal_phase_reached?(intent.id, :required_comment_applied) do
      :ok
    else
      case Tracker.create_comment_once(intent.issue_id, body, marker) do
        result when result in [:applied, :already_applied] ->
          normalize_journal_record(
            journal_record(intent.id, :required_comment_applied, %{
              comment_marker: marker,
              comment_status: result
            })
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp record_rejection_projection(intent, projection) do
    normalize_journal_record(journal_record(intent.id, :projection_applied, %{projection: projection}))
  end

  defp apply_rejection_projection_once(intent, state) do
    if journal_phase_reached?(intent.id, :projection_applied) do
      :ok
    else
      case Tracker.apply_state_projection(intent.issue_id, :any, state) do
        projection when elem(projection, 0) in [:applied, :already_applied] ->
          record_rejection_projection(intent, projection)

        {:conflict, snapshot} ->
          {:error, {:reconciliation_conflict, snapshot}}

        {:partial_failure, details} ->
          {:error, {:reconciliation_partial_failure, details}}
      end
    end
  end

  defp rejected_request_marker(intent, issue, reason) do
    request_labels =
      issue.labels
      |> List.wrap()
      |> Enum.filter(&String.starts_with?(&1, "sym:request-"))
      |> Enum.sort()

    category =
      case reason do
        {:ambiguous_request_labels, _, _} -> :ambiguous_request_labels
        {:missing_request_label, _} -> :missing_request_label
        {name, _, _} when is_atom(name) -> name
        name when is_atom(name) -> name
      end

    digest = payload_digest({intent.issue_id, issue.state, category, request_labels})
    "<!-- sym-transition:request-rejected:#{digest} -->"
  end

  defp apply_tracker_projection(plan) do
    if journal_phase_reached?(plan.id, :projection_applied) do
      verify_replayed_projection(plan)
    else
      apply_tracker_projection_effect(plan)
    end
  end

  defp verify_replayed_projection(plan) do
    case fetch_transition_issue(plan.issue_id) do
      {:ok, %{state: state}} when state == plan.to_state ->
        {:ok, %{status: :replayed, state: state}}

      {:ok, issue} ->
        {:conflict, %{issue_id: plan.issue_id, expected_state: plan.to_state, state: issue.state}}

      {:error, reason} ->
        {:error, {:projection_readback_failed, reason}}
    end
  end

  defp apply_tracker_projection_effect(plan) do
    case Tracker.apply_state_projection(plan.issue_id, plan.from_state, plan.to_state) do
      {:applied, metadata} ->
        record_projection_applied(plan, metadata, :applied)

      {:already_applied, metadata} ->
        record_projection_applied(plan, metadata, :already_applied)

      {:conflict, %{reason: {:forgejo_parent_completion_deferred, _number}} = snapshot} ->
        defer_forgejo_parent_completion(plan, snapshot)

      {:conflict, snapshot} ->
        {:conflict, snapshot}

      {:partial_failure, details} ->
        {:error, {:projection_partial_failure, details}}
    end
  end

  defp defer_forgejo_parent_completion(plan, snapshot) do
    with {:ok, issue} <- fetch_transition_issue(plan.issue_id),
         intent = %TransitionIntent{
           id: transition_id("parent-terminal-deferred", issue.id, issue.state),
           issue_id: issue.id,
           source: :orchestrator,
           actor: "symphony",
           expected_state: issue.state,
           kind: :handoff_required,
           work_item_kind: issue.kind,
           causation_id: plan.id,
           comment_body: "Symphony가 아직 완료되지 않은 Forgejo 하위 이슈를 확인했습니다. 부모 이슈의 완료는 모든 하위 이슈가 종료된 뒤 별도 전이로 처리합니다."
         },
         {:ok, _} <- apply_dispatch_transition(intent, issue) do
      {:deferred, %{snapshot: snapshot, transition_id: intent.id}}
    else
      {:error, reason} -> {:error, {:parent_completion_handoff_failed, reason}}
      other -> {:error, {:parent_completion_handoff_failed, other}}
    end
  end

  defp maybe_complete_forgejo_parent(state, %{issue_id: issue_id, to_state: target, id: causation_id})
       when is_binary(issue_id) do
    if Config.settings!().tracker.kind == "forgejo" and terminal_issue_state?(target, terminal_state_set()) do
      complete_forgejo_parent_after_child(state, issue_id, causation_id)
    else
      {:ok, state}
    end
  end

  defp complete_forgejo_parent_after_child(state, child_id, causation_id) do
    with {:ok, %Issue{kind: :issue, metadata: metadata}} <- fetch_transition_issue(child_id),
         parent_number when is_integer(parent_number) <- metadata[:parent_number] || metadata["parent_number"],
         {:ok, %Issue{} = parent} <- fetch_transition_issue("forgejo:issue:#{parent_number}") do
      intent = %TransitionIntent{
        id: transition_id("parent-children-completed", parent.id, parent.state),
        issue_id: parent.id,
        source: :orchestrator,
        actor: "symphony",
        expected_state: parent.state,
        kind: :children_completed,
        work_item_kind: parent.kind,
        causation_id: causation_id
      }

      case apply_dispatch_transition(intent, parent) do
        {:ok, _} ->
          {:ok, state}

        {:noop, :already_applied} ->
          {:ok, state}

        {:conflict, snapshot} ->
          {:error, {:parent_completion_transition_conflict, snapshot}}

        {:error, reason} ->
          {:error, {:parent_completion_transition_failed, reason}}

        other ->
          {:error, {:parent_completion_transition_failed, other}}
      end
    else
      # A child without a declared Forgejo parent is a normal terminal
      # transition.  A malformed relationship is already rejected by the
      # Forgejo adapter during normalization.
      _ -> {:ok, state}
    end
  end

  defp record_projection_applied(plan, metadata, status) do
    with :ok <-
           normalize_journal_record(journal_record(plan.id, :projection_applied, %{projection: metadata})) do
      {:ok, Map.put(metadata, :status, status)}
    end
  end

  defp journal_retry(plan, reason) do
    journal_retry(plan, reason, %{})
  end

  defp journal_retry(plan, reason, extra) do
    data =
      plan
      |> transition_plan_data()
      |> Map.merge(extra)
      |> Map.put(:retry_reason, inspect(reason))

    journal_record(plan.id, :retrying, data)
  end

  defp journal_retry_for_intent(intent, reason) do
    journal_record(
      intent.id,
      :retrying,
      Map.put(transition_intent_data(intent), :retry_reason, inspect(reason))
    )
  end

  defp journal_record(transition_id, phase, data) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) -> TransitionJournal.record(pid, transition_id, phase, data)
      _ -> {:error, :transition_journal_unavailable}
    end
  end

  defp journal_snapshot(transition_id) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) -> TransitionJournal.snapshot(pid, transition_id)
      _ -> :error
    end
  end

  defp normalize_journal_record({:ok, _event}), do: :ok
  defp normalize_journal_record({:noop, _reason}), do: :ok
  defp normalize_journal_record({:error, reason}), do: {:error, reason}

  defp journal_phase_reached?(transition_id, wanted_phase) do
    case journal_snapshot(transition_id) do
      {:ok, %{history: history}} ->
        Enum.any?(history, &(&1.phase == wanted_phase or &1.phase == :verified))

      :error ->
        false
    end
  end

  defp transition_intent_data(intent) do
    %{
      issue_id: intent.issue_id,
      source: intent.source,
      actor: intent.actor,
      expected_state: intent.expected_state,
      kind: intent.kind,
      causation_id: intent.causation_id,
      head_oid: intent.head_oid,
      work_item_kind: intent.work_item_kind,
      review_attempt: intent.review_attempt,
      review_limit: intent.review_limit,
      comment_body: intent.comment_body,
      metadata: intent.metadata
    }
  end

  defp transition_plan_data(plan, extra \\ %{}) do
    Map.merge(
      %{
        issue_id: plan.issue_id,
        from_state: plan.from_state,
        to_state: plan.to_state,
        source: plan.source,
        actor: plan.actor,
        kind: plan.kind,
        causation_id: plan.causation_id,
        head_oid: plan.head_oid,
        comment_body: plan.comment_body,
        metadata: plan.metadata
      },
      extra
    )
  end

  defp replay_pending_transitions(state) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) ->
        state =
          pid
          |> TransitionJournal.pending()
          |> Enum.reduce(state, &replay_pending_transition/2)

        recover_orphaned_worker_dispatches(pid, state)

      _ ->
        state
    end
  end

  defp recover_orphaned_worker_dispatches(journal, state) do
    events = TransitionJournal.replay(journal)

    events
    |> Enum.filter(&verified_worker_dispatch_event?/1)
    |> Enum.group_by(& &1.data[:issue_id])
    |> Enum.map(fn {_issue_id, leases} -> Enum.max_by(leases, & &1.recorded_at) end)
    |> Enum.reject(&worker_outcome_recorded_after?(events, &1))
    |> Enum.reduce(state, &recover_orphaned_worker_dispatch/2)
  end

  defp verified_worker_dispatch_event?(event) do
    event.phase == :verified and String.starts_with?(event.transition_id, "worker-dispatch:")
  end

  defp worker_outcome_recorded_after?(events, lease) do
    events
    |> events_after(lease)
    |> Enum.any?(&worker_outcome_for_issue?(&1, lease.data[:issue_id]))
  end

  defp events_after(events, target) do
    case Enum.split_while(events, &(&1 != target)) do
      {_before, [_target | after_target]} -> after_target
      {_before, []} -> []
    end
  end

  defp worker_outcome_for_issue?(event, issue_id) do
    event.phase == :verified and event.data[:issue_id] == issue_id and
      event.data[:kind] in [
        :planning_complete,
        :implementation_complete,
        :rework_complete,
        :clean_review,
        :review_findings,
        :merge_ready,
        :blocked,
        :handoff_required
      ]
  end

  defp recover_orphaned_worker_dispatch(event, state) do
    issue_id = event.data[:issue_id]
    lease = %{transition_id: event.transition_id, data: %{issue_id: issue_id}}
    handoff_ambiguous_worker_dispatch(state, lease, issue_id)
  end

  defp replay_pending_transition(snapshot, state) do
    case replay_provider_mismatch(snapshot) do
      nil ->
        replay_pending_transition_for_provider(snapshot, state)

      mismatch ->
        Logger.error("Quarantined transition journal entry after tracker provider change transition_id=#{snapshot.transition_id} reason=#{inspect(mismatch)}")

        _ = quarantine_provider_mismatch(snapshot, mismatch)

        %{state | transition_conflicts: state.transition_conflicts + 1}
    end
  end

  defp replay_pending_transition_for_provider(
         %{
           transition_id: "worker-dispatch:" <> _rest,
           phase: :projection_applied,
           data: %{issue_id: issue_id}
         } = lease,
         state
       ) do
    Logger.warning("Recovered an ambiguous worker dispatch lease; fail-closed issue_id=#{issue_id}")

    handoff_ambiguous_worker_dispatch(state, lease, issue_id)
  end

  defp replay_pending_transition_for_provider(
         %{transition_id: "worker-dispatch:" <> _rest},
         state
       ),
       do: state

  defp replay_pending_transition_for_provider(snapshot, state) do
    {result, next_state} = resume_transition_snapshot(snapshot, state)
    log_replay_result(snapshot.transition_id, result)
    _ = schedule_transition_effect_retry(result, snapshot.transition_id)
    next_state
  end

  defp replay_provider_mismatch(%{data: %{issue_id: issue_id}}) when is_binary(issue_id) do
    current = Config.settings!().tracker.kind

    if current == "memory" do
      nil
    else
      case issue_id do
        "github:" <> _rest when current != "github" ->
          {:tracker_provider_mismatch, "github", current, issue_id}

        "forgejo:" <> _rest when current != "forgejo" ->
          {:tracker_provider_mismatch, "forgejo", current, issue_id}

        _ ->
          nil
      end
    end
  end

  defp replay_provider_mismatch(_snapshot), do: nil

  defp quarantine_provider_mismatch(snapshot, mismatch) do
    data = %{
      issue_id: snapshot.data[:issue_id],
      quarantined: true,
      reason: mismatch
    }

    with :ok <- advance_quarantine_phase(snapshot.transition_id, snapshot.phase, :decided, data),
         :ok <-
           advance_quarantine_phase(
             snapshot.transition_id,
             snapshot.phase,
             :projection_applied,
             data
           ) do
      normalize_journal_record(journal_record(snapshot.transition_id, :verified, data))
    end
  end

  defp advance_quarantine_phase(_transition_id, current, :decided, _data)
       when current in [:decided, :required_comment_applied, :projection_applied, :retrying],
       do: :ok

  defp advance_quarantine_phase(transition_id, :received, :decided, data),
    do: normalize_journal_record(journal_record(transition_id, :decided, data))

  defp advance_quarantine_phase(_transition_id, current, :projection_applied, _data)
       when current in [:projection_applied, :retrying],
       do: :ok

  defp advance_quarantine_phase(transition_id, current, :projection_applied, data)
       when current in [:received, :decided, :required_comment_applied],
       do: normalize_journal_record(journal_record(transition_id, :projection_applied, data))

  defp handoff_ambiguous_worker_dispatch(state, lease, issue_id) do
    intent = %TransitionIntent{
      id: "ambiguous-worker-handoff:#{lease.transition_id}",
      issue_id: issue_id,
      source: :journal_recovery,
      actor: "symphony",
      kind: :handoff_required,
      causation_id: lease.transition_id,
      comment_body:
        "Symphony 재시작 중 worker dispatch 완료 여부를 안전하게 확인할 수 없어 사람 검토로 인계합니다.\n\n" <>
          "- dispatch lease: #{lease.transition_id}"
    }

    case apply_transition_intent(state, intent) do
      {{:ok, _applied}, next_state} ->
        next_state

      {result, next_state} ->
        _ = schedule_transition_effect_retry(result, intent.id)
        %{next_state | claimed: MapSet.put(next_state.claimed, issue_id)}
    end
  end

  defp retry_transition_effect(transition_id, state) do
    case journal_snapshot(transition_id) do
      {:ok, %{phase: :verified}} -> {{:noop, :already_applied}, state}
      {:ok, snapshot} -> resume_transition_snapshot(snapshot, state)
      :error -> {{:error, :transition_journal_entry_not_found}, state}
    end
  end

  defp resume_transition_snapshot(%{data: %{effect: :dispatch_receipt}} = snapshot, state) do
    case complete_planning_dispatch_receipt(
           snapshot.transition_id,
           snapshot.phase,
           snapshot.data
         ) do
      :ok -> {{:noop, :dispatch_receipt_completed}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp resume_transition_snapshot(snapshot, state) do
    case snapshot.data[:handoff_transition_id] do
      handoff_id when is_binary(handoff_id) and handoff_id != "" ->
        resume_handoff_transition(snapshot, handoff_id, state)

      _ ->
        case pending_transition_plan(snapshot) do
          {:ok, plan} -> resume_decided_transition(snapshot, state, plan)
          :error -> replay_received_transition_result(snapshot, state)
        end
    end
  end

  defp resume_handoff_transition(snapshot, handoff_id, state) do
    {result, next_state} = retry_transition_effect(handoff_id, state)

    if handoff_completed?(result) do
      _ =
        normalize_journal_record(
          journal_record(snapshot.transition_id, :verified, %{
            issue_id: snapshot.data[:issue_id],
            abandoned_effect: true,
            handoff_transition_id: handoff_id
          })
        )
    end

    {result, next_state}
  end

  defp handoff_completed?({:ok, _applied}), do: true
  defp handoff_completed?({:noop, :already_applied}), do: true
  defp handoff_completed?(_result), do: false

  defp resume_decided_transition(snapshot, state, plan) do
    case transition_snapshot_mode(snapshot) do
      "shadow" -> apply_shadow_plan(state, plan, false)
      _ -> apply_authoritative_plan(state, plan, false)
    end
  end

  defp transition_snapshot_mode(%{history: history}) do
    Enum.find_value(Enum.reverse(history), fn event -> event.data[:mode] end)
  end

  defp pending_transition_plan(%{history: history, transition_id: transition_id}) do
    Enum.find_value(Enum.reverse(history), :error, fn event ->
      if event.phase in [:decided, :retrying] and Map.has_key?(event.data, :from_state) do
        {:ok, transition_plan_from_data(transition_id, event.data)}
      end
    end)
  end

  defp transition_plan_from_data(transition_id, data) do
    %TransitionPlan{
      id: transition_id,
      issue_id: data[:issue_id],
      from_state: data[:from_state],
      to_state: data[:to_state],
      source: data[:source],
      actor: data[:actor],
      kind: data[:kind],
      head_oid: data[:head_oid],
      causation_id: data[:causation_id],
      comment_body: data[:comment_body],
      metadata: data[:metadata] || %{}
    }
  end

  defp replay_received_transition_result(%{transition_id: transition_id, data: data}, state) do
    intent = %TransitionIntent{
      id: transition_id,
      issue_id: data[:issue_id],
      source: data[:source],
      actor: data[:actor],
      expected_state: data[:expected_state],
      kind: data[:kind],
      head_oid: data[:head_oid],
      causation_id: data[:causation_id],
      work_item_kind: data[:work_item_kind],
      review_attempt: data[:review_attempt],
      review_limit: data[:review_limit],
      comment_body: data[:comment_body],
      metadata: data[:metadata] || %{}
    }

    {result, next_state} = apply_transition_intent(state, intent)
    {result, next_state}
  end

  defp log_replay_result(transition_id, result) do
    Logger.info("Replayed transition journal entry transition_id=#{transition_id} result=#{inspect(result)}")
  end

  defp state_manager_snapshot(state) do
    pending =
      case Process.whereis(TransitionJournal) do
        pid when is_pid(pid) -> TransitionJournal.pending(pid)
        _ -> []
      end

    %{
      mode: Config.settings!().state_manager.mode,
      journal_available?: is_pid(Process.whereis(TransitionJournal)),
      pending_transitions: length(pending),
      conflicts: state.transition_conflicts,
      last_transition: state.last_transition
    }
  end

  defp transition_intent_from_tracker_event(intent) do
    issue_id = intent_value(intent, :issue_id)
    event_kind = intent_value(intent, :kind)
    id = intent_id(intent)

    attributes = %{
      id: to_string(id),
      issue_id: issue_id,
      source: tracker_event_source(intent),
      actor: intent_value(intent, :actor),
      kind: tracker_event_transition_kind(event_kind, intent),
      head_oid: intent_value(intent, :head_oid),
      causation_id: to_string(id),
      work_item_kind: tracker_work_item_kind(issue_id),
      metadata: intent
    }

    case attributes.kind do
      nil -> {:error, {:ignored_tracker_intent, event_kind}}
      _ -> TransitionIntent.new(attributes)
    end
  end

  defp intent_value(intent, key), do: Map.get(intent, key) || Map.get(intent, Atom.to_string(key))

  defp intent_id(intent) do
    source = tracker_event_source(intent)

    raw_id =
      case intent_value(intent, :delivery_id) || intent_value(intent, :id) do
        id when is_binary(id) and id != "" -> id
        _ -> "payload:#{payload_digest(intent)}"
      end

    "#{source}:#{raw_id}"
  end

  defp payload_digest(intent) do
    :crypto.hash(:sha256, :erlang.term_to_binary(intent))
    |> Base.encode16(case: :lower)
  end

  defp tracker_work_item_kind("github:pr:" <> _number), do: :pull_request
  defp tracker_work_item_kind("forgejo:pr:" <> _number), do: :pull_request
  defp tracker_work_item_kind(_issue_id), do: :issue

  defp tracker_event_source(intent) do
    case intent_value(intent, :source) do
      source when source in [:github_webhook, :forgejo_webhook] -> source
      "github_webhook" -> :github_webhook
      "forgejo_webhook" -> :forgejo_webhook
      _ -> nil
    end
  end

  defp tracker_event_transition_kind(:operator_transition_requested, intent),
    do: {:operator_request, Map.get(intent, :label) || Map.get(intent, "label")}

  defp tracker_event_transition_kind(:pull_request_closed, intent) do
    if Map.get(intent, :merged) || Map.get(intent, "merged"),
      do: :merge_observed,
      else: :closed_unmerged
  end

  defp tracker_event_transition_kind(:issue_closed, _intent), do: {:operator_request, :canceled}

  defp tracker_event_transition_kind(:review_feedback_detected, _intent),
    do: {:operator_request, :rework}

  defp tracker_event_transition_kind(:projection_echo, _intent), do: nil
  defp tracker_event_transition_kind(:state_projection_drift, _intent), do: nil
  defp tracker_event_transition_kind(:head_updated, _intent), do: nil
  defp tracker_event_transition_kind(:review_submitted, _intent), do: nil
  defp tracker_event_transition_kind(:item_reopened, _intent), do: {:operator_request, :reopen}
  defp tracker_event_transition_kind(_kind, _intent), do: nil

  defp safe_orchestrator_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> :unavailable
  end

  defp reconcile_projection_drift(state, intent) do
    issue_id = Map.get(intent, :issue_id) || Map.get(intent, "issue_id")
    observed_state = Map.get(intent, :observed_state) || Map.get(intent, "observed_state")

    case committed_state_for_issue(issue_id) do
      {:ok, committed_state} when committed_state == observed_state ->
        {{:noop, :projection_confirmed}, state}

      {:ok, committed_state} ->
        reconcile_live_projection_drift(state, issue_id, observed_state, committed_state)

      :error ->
        reconcile_projection_drift_without_committed_state(state, intent)
    end
  end

  defp reconcile_projection_drift_without_committed_state(state, intent) do
    case tracker_event_source(intent) do
      source when source in [:github_webhook, :forgejo_webhook] ->
        {record_refresh_only_tracker_intent(intent, :canonical_state_unavailable), state}

      _ ->
        {{:error, :canonical_state_unavailable}, state}
    end
  end

  defp reconcile_live_projection_drift(state, issue_id, observed_state, committed_state) do
    case fetch_transition_issue(issue_id) do
      {:ok, issue} ->
        cond do
          issue.state == committed_state ->
            {{:noop, :projection_already_reconciled}, state}

          physically_terminal_issue?(issue) ->
            {{:noop, :terminal_state}, state}

          true ->
            apply_projection_drift_reconciliation(state, issue_id, observed_state, committed_state)
        end

      {:error, :transition_issue_not_found} ->
        apply_projection_drift_reconciliation(state, issue_id, observed_state, committed_state)

      {:error, reason} ->
        {{:error, {:projection_drift_readback_failed, reason}}, state}
    end
  end

  defp physically_terminal_issue?(%Issue{metadata: metadata}) do
    metadata = metadata || %{}
    merged = metadata[:merged] || metadata["merged"]
    physical_state = metadata[:physical_state] || metadata["physical_state"]

    merged == true or physical_state in ["closed", :closed]
  end

  defp apply_projection_drift_reconciliation(state, issue_id, observed_state, committed_state) do
    digest = payload_digest({issue_id, observed_state, committed_state})
    marker = "<!-- sym-transition:projection-drift:#{digest} -->"

    body =
      "Symphony가 직접 변경된 상태 라벨을 마지막 검증 상태로 복구했습니다.\n\n" <>
        "- 복구 상태: #{committed_state}"

    case Tracker.create_comment_once(issue_id, body, marker) do
      comment when comment in [:applied, :already_applied] ->
        case Tracker.apply_state_projection(issue_id, :any, committed_state) do
          result when elem(result, 0) in [:applied, :already_applied] ->
            {{:ok, %{reconciled: true, state: committed_state}}, state}

          {:conflict, snapshot} ->
            {{:conflict, snapshot}, %{state | transition_conflicts: state.transition_conflicts + 1}}

          {:partial_failure, details} ->
            {{:error, {:projection_partial_failure, details}}, state}
        end

      {:error, reason} ->
        {{:error, {:projection_drift_comment_failed, reason}}, state}
    end
  end

  defp committed_state_for_issue(issue_id) when is_binary(issue_id) do
    case Process.whereis(TransitionJournal) do
      pid when is_pid(pid) ->
        pid
        |> TransitionJournal.replay()
        |> Enum.reverse()
        |> Enum.find_value(:error, &verified_state_for_issue(&1, issue_id))

      _ ->
        :error
    end
  end

  defp committed_state_for_issue(_issue_id), do: :error

  defp verified_state_for_issue(
         %{phase: :verified, data: %{issue_id: issue_id, to_state: state}},
         issue_id
       ),
       do: {:ok, state}

  defp verified_state_for_issue(_event, _issue_id), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    running_entry = reset_token_baseline_for_new_session(running_entry, update)
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp reset_token_baseline_for_new_session(
         %{session_id: existing_session_id} = running_entry,
         %{event: :session_started, session_id: next_session_id}
       )
       when is_binary(next_session_id) and next_session_id != existing_session_id do
    Map.merge(running_entry, %{
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0
    })
  end

  defp reset_token_baseline_for_new_session(running_entry, _update), do: running_entry

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !human_intent_request_present?(issue) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
