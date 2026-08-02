defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, StateManager, Tracker.Issue, TransitionIntent}

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "forgejo" => SymphonyElixir.Forgejo.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback preflight() :: :ok | {:error, term()}
  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_dispatch_snapshot(Issue.t()) :: {:ok, map()} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment_once(String.t(), String.t(), String.t()) ::
              :applied | :already_applied | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
              {:applied, map()}
              | {:already_applied, map()}
              | {:conflict, map()}
              | {:partial_failure, map()}
  @callback create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  @callback merge_pull_request(String.t(), String.t()) ::
              {:applied, map()} | {:conflict, map()} | {:error, map()}
  @callback close_review_threads(String.t(), String.t(), [map()], String.t()) ::
              {:applied, map()} | {:handoff, term(), map()} | {:retry, term(), map()} | {:conflict, map()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}

  @optional_callbacks preflight: 0,
                      fetch_candidate_issues: 0,
                      fetch_issue_states_by_ids: 1,
                      fetch_issues_by_ids: 1,
                      fetch_dispatch_snapshot: 1,
                      create_comment: 2,
                      create_comment_once: 3,
                      update_issue_state: 2,
                      apply_state_projection: 3,
                      create_pull_request_for_issue: 1,
                      merge_pull_request: 2,
                      close_review_threads: 4,
                      agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      secret_environment_names: 1,
                      validate_config: 1

  @spec preflight() :: :ok | {:error, term()}
  def preflight do
    selected = adapter()
    if function_exported?(selected, :preflight, 0), do: selected.preflight(), else: :ok
  end

  @doc """
  Returns whether dispatch or a broker-owned write may proceed.

  Forgejo's supported-major check is deliberately applied at every write and
  dispatch boundary. Reads remain available for dashboards and recovery.
  """
  @spec write_ready?() :: :ok | {:error, term()}
  def write_ready? do
    if Config.settings!().tracker.kind == "forgejo", do: preflight(), else: :ok
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    selected = adapter()

    if function_exported?(selected, :fetch_candidate_issues, 0) do
      selected.fetch_candidate_issues()
    else
      selected.fetch_issues_by_states(Config.settings!().tracker.active_states)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    with :ok <- validate_issue_providers(issue_ids) do
      selected = adapter()

      if function_exported?(selected, :fetch_issue_states_by_ids, 1) do
        selected.fetch_issue_states_by_ids(issue_ids)
      else
        selected.fetch_issues_by_ids(issue_ids)
      end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: fetch_issue_states_by_ids(issue_ids)

  @doc "Reads broker-owned live evidence for a worker dispatch."
  @spec fetch_dispatch_snapshot(Issue.t()) :: {:ok, map()} | {:error, term()}
  def fetch_dispatch_snapshot(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    with :ok <- validate_issue_provider(issue_id) do
      selected = adapter()

      if function_exported?(selected, :fetch_dispatch_snapshot, 1) do
        selected.fetch_dispatch_snapshot(issue)
      else
        {:error, {:dispatch_snapshot_unsupported, Config.settings!().tracker.kind, issue_id}}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    with :ok <- validate_issue_provider(issue_id), :ok <- write_ready?() do
      call_adapter_write(:create_comment, [issue_id, body])
    end
  end

  @spec create_comment_once(String.t(), String.t(), String.t()) ::
          :applied | :already_applied | {:error, term()}
  def create_comment_once(issue_id, body, marker) do
    with :ok <- validate_issue_provider(issue_id), :ok <- write_ready?() do
      call_adapter_write(:create_comment_once, [issue_id, body, marker])
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    with :ok <- validate_issue_provider(issue_id), :ok <- write_ready?() do
      if Config.settings!().state_manager.mode == "authoritative" do
        request_legacy_state_transition(issue_id, state_name)
      else
        call_adapter_write(:update_issue_state, [issue_id, state_name])
      end
    end
  end

  @spec apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
          {:applied, map()}
          | {:already_applied, map()}
          | {:conflict, map()}
          | {:partial_failure, map()}
  def apply_state_projection(issue_id, expected_state, target_state) do
    case {validate_issue_provider(issue_id), write_ready?()} do
      {:ok, :ok} -> call_adapter_projection(issue_id, expected_state, target_state)
      {:ok, {:error, reason}} -> {:conflict, %{issue_id: issue_id, reason: reason}}
      {{:error, reason}, _} -> {:conflict, %{issue_id: issue_id, reason: reason}}
    end
  end

  @spec create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def create_pull_request_for_issue(%Issue{} = issue) do
    with :ok <- validate_issue_provider(issue.id), :ok <- write_ready?() do
      call_adapter_write(:create_pull_request_for_issue, [issue])
    end
  end

  @spec merge_pull_request(String.t(), String.t()) ::
          {:applied, map()} | {:conflict, map()} | {:error, map()}
  def merge_pull_request(issue_id, expected_head_oid) do
    case {validate_issue_provider(issue_id), write_ready?()} do
      {:ok, :ok} -> call_adapter_merge(issue_id, expected_head_oid)
      {:ok, {:error, reason}} -> {:error, %{stage: :preflight, reason: reason}}
      {{:error, reason}, _} -> {:error, %{stage: :validate, reason: reason}}
    end
  end

  @spec close_review_threads(String.t(), String.t(), [map()], String.t()) ::
          {:applied, map()} | {:handoff, term(), map()} | {:retry, term(), map()} | {:conflict, map()}
  def close_review_threads(issue_id, expected_head_oid, updates, marker) do
    case {validate_issue_provider(issue_id), write_ready?()} do
      {:ok, :ok} -> call_adapter_closeout(issue_id, expected_head_oid, updates, marker)
      {:ok, {:error, reason}} -> {:handoff, :review_thread_closeout_unsupported, %{issue_id: issue_id, reason: reason}}
      {{:error, reason}, _} -> {:conflict, %{issue_id: issue_id, reason: reason}}
    end
  end

  @spec adapter() :: module()
  def adapter do
    {:ok, selected} = adapter_for_kind(Config.settings!().tracker.kind)
    selected
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, selected} -> {:ok, selected}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, selected} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(selected) and function_exported?(selected, :validate_config, 1) do
        selected.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    selected = adapter()

    %{
      adapter: selected,
      tracker_settings: tracker_settings,
      tool_specs: adapter_tool_specs(selected),
      secret_environment_names: adapter_secret_environment_names(selected, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t() | nil, term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: selected, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    if function_exported?(selected, :execute_agent_tool, 3) do
      selected.execute_agent_tool(
        tool,
        arguments,
        Keyword.put(opts, :tracker_settings, tracker_settings)
      )
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_tool_specs(selected) do
    if function_exported?(selected, :agent_tool_specs, 0), do: selected.agent_tool_specs(), else: []
  end

  defp adapter_secret_environment_names(selected, tracker_settings) do
    configured = Map.get(tracker_settings, :secret_environment_names, [])

    provider_names =
      if function_exported?(selected, :secret_environment_names, 1) do
        selected.secret_environment_names(tracker_settings)
      else
        []
      end

    Enum.uniq(provider_names ++ configured)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp call_adapter_write(function, arguments) do
    selected = adapter()

    if function_exported?(selected, function, length(arguments)) do
      apply(selected, function, arguments)
    else
      {:error, {:unsupported_tracker_write, Config.settings!().tracker.kind, function}}
    end
  end

  defp call_adapter_projection(issue_id, expected_state, target_state) do
    selected = adapter()

    if function_exported?(selected, :apply_state_projection, 3) do
      selected.apply_state_projection(issue_id, expected_state, target_state)
    else
      {:conflict,
       %{
         issue_id: issue_id,
         expected_state: expected_state,
         target_state: target_state,
         reason: {:unsupported_tracker_write, Config.settings!().tracker.kind, :apply_state_projection}
       }}
    end
  end

  defp call_adapter_merge(issue_id, expected_head_oid) do
    selected = adapter()

    if function_exported?(selected, :merge_pull_request, 2) do
      selected.merge_pull_request(issue_id, expected_head_oid)
    else
      {:error,
       %{
         stage: :validate,
         reason: {:unsupported_tracker_write, Config.settings!().tracker.kind, :merge_pull_request}
       }}
    end
  end

  defp call_adapter_closeout(issue_id, expected_head_oid, updates, marker) do
    selected = adapter()

    if function_exported?(selected, :close_review_threads, 4) do
      selected.close_review_threads(issue_id, expected_head_oid, updates, marker)
    else
      {:handoff, :review_thread_closeout_unsupported, %{issue_id: issue_id, provider: Config.settings!().tracker.kind}}
    end
  end

  defp validate_issue_providers(issue_ids) when is_list(issue_ids) do
    Enum.reduce_while(issue_ids, :ok, fn issue_id, :ok ->
      case validate_issue_provider(issue_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_issue_provider(issue_id) when is_binary(issue_id) do
    current_provider = Config.settings!().tracker.kind

    case {current_provider, issue_provider(issue_id)} do
      {"memory", _provider} -> :ok
      {_current, nil} -> :ok
      {provider, provider} -> :ok
      {current, provider} -> {:error, {:tracker_provider_mismatch, provider, current, issue_id}}
    end
  end

  defp validate_issue_provider(_issue_id), do: :ok

  defp issue_provider("github:" <> _rest), do: "github"
  defp issue_provider("forgejo:" <> _rest), do: "forgejo"
  defp issue_provider(_issue_id), do: nil

  defp request_legacy_state_transition(issue_id, state_name) do
    case fetch_issue_states_by_ids([issue_id]) do
      {:ok, [issue | _]} -> request_legacy_state_transition_for_issue(issue, state_name)
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_legacy_state_transition_for_issue(%{state: state}, state), do: :ok

  defp request_legacy_state_transition_for_issue(issue, state_name) do
    case legacy_transition_kind(issue.state, state_name) do
      {:ok, kind} -> request_legacy_state_transition_kind(issue, kind)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_legacy_state_transition_kind(issue, kind) do
    intent = %TransitionIntent{
      id: "legacy-api:#{issue.id}:#{System.unique_integer([:positive, :monotonic])}",
      issue_id: issue.id,
      source: :legacy_api,
      actor: "symphony-compat",
      expected_state: issue.state,
      kind: kind,
      work_item_kind: issue.kind,
      causation_id: issue.id
    }

    case StateManager.request(intent) do
      {:ok, _applied} -> :ok
      {:noop, _reason} -> :ok
      {:conflict, snapshot} -> {:error, {:state_transition_conflict, snapshot}}
      {:rejected, reason} -> {:error, {:state_transition_rejected, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_transition_kind("Planned", "In Progress"), do: {:ok, :dispatch_implementation}
  defp legacy_transition_kind("Review", "Reviewing"), do: {:ok, :dispatch_review}
  defp legacy_transition_kind("Rework", "Reworking"), do: {:ok, :dispatch_rework}
  defp legacy_transition_kind("In Progress", "Review"), do: {:ok, :implementation_complete}
  defp legacy_transition_kind("Reworking", "Review"), do: {:ok, :rework_complete}
  defp legacy_transition_kind(_current, "Human Review"), do: {:ok, :handoff_required}
  defp legacy_transition_kind("Merging", "Done"), do: {:ok, :merge_observed}
  defp legacy_transition_kind(_current, "Planned"), do: {:ok, {:operator_request, :planned}}
  defp legacy_transition_kind(_current, "Rework"), do: {:ok, {:operator_request, :rework}}
  defp legacy_transition_kind(_current, "Merging"), do: {:ok, {:operator_request, :merging}}
  defp legacy_transition_kind(_current, "Canceled"), do: {:ok, {:operator_request, :canceled}}
  defp legacy_transition_kind(_current, "Duplicate"), do: {:ok, {:operator_request, :duplicate}}
  defp legacy_transition_kind(current, target), do: {:error, {:semantic_transition_required, current, target}}
end
