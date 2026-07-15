defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: client_module().update_issue_state(issue_id, state_name)

  @spec sync_webhook_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def sync_webhook_state(event, action, payload), do: client_module().sync_webhook_state(event, action, payload)

  @spec queue_rework_from_review_comment(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def queue_rework_from_review_comment(event, action, payload),
    do: client_module().queue_rework_from_review_comment(event, action, payload)

  @spec create_pull_request_for_issue(term()) :: {:ok, term()} | {:error, term()}
  def create_pull_request_for_issue(issue), do: client_module().create_pull_request_for_issue(issue)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
