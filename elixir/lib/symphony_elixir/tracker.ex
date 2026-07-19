defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, StateManager, Tracker.Issue, TransitionIntent}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
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

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment_once(String.t(), String.t(), String.t()) ::
          :applied | :already_applied | {:error, term()}
  def create_comment_once(issue_id, body, marker) do
    adapter().create_comment_once(issue_id, body, marker)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @deprecated "Submit a TransitionIntent through StateManager.request/1 instead"
  def update_issue_state(issue_id, state_name) do
    if Config.settings!().state_manager.mode == "authoritative" do
      request_legacy_state_transition(issue_id, state_name)
    else
      adapter().update_issue_state(issue_id, state_name)
    end
  end

  @spec apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
          {:applied, map()}
          | {:already_applied, map()}
          | {:conflict, map()}
          | {:partial_failure, map()}
  def apply_state_projection(issue_id, expected_state, target_state) do
    adapter().apply_state_projection(issue_id, expected_state, target_state)
  end

  @spec create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def create_pull_request_for_issue(%Issue{} = issue) do
    adapter().create_pull_request_for_issue(issue)
  end

  @spec merge_pull_request(String.t(), String.t()) ::
          {:applied, map()} | {:conflict, map()} | {:error, map()}
  def merge_pull_request(issue_id, expected_head_oid) do
    adapter().merge_pull_request(issue_id, expected_head_oid)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "linear" -> SymphonyElixir.Linear.Adapter
      "github" -> SymphonyElixir.GitHub.Adapter
      "memory" -> SymphonyElixir.Tracker.Memory
    end
  end

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
