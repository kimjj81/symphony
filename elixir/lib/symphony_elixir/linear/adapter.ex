defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @spec preflight() :: :ok
  def preflight, do: :ok

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @comments_query """
  query SymphonyIssueComments($issueId: String!, $before: String) {
    issue(id: $issueId) {
      comments(last: 100, before: $before) {
        nodes {
          body
        }
        pageInfo {
          hasPreviousPage
          startCursor
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_comment_once(String.t(), String.t(), String.t()) ::
          :applied | :already_applied | {:error, term()}
  def create_comment_once(issue_id, body, marker)
      when is_binary(issue_id) and is_binary(body) and is_binary(marker) and marker != "" do
    with {:ok, comments} <- fetch_all_linear_comments(issue_id) do
      if Enum.any?(comments, &String.contains?(&1, marker)) do
        :already_applied
      else
        create_marked_linear_comment(issue_id, body, marker)
      end
    end
  end

  def create_comment_once(_issue_id, _body, _marker), do: {:error, :invalid_comment_marker}

  defp create_marked_linear_comment(issue_id, body, marker) do
    case create_comment(issue_id, body <> "\n\n" <> marker) do
      :ok -> :applied
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
          {:applied, map()}
          | {:already_applied, map()}
          | {:conflict, map()}
          | {:partial_failure, map()}
  def apply_state_projection(issue_id, expected_state, target_state)
      when is_binary(issue_id) and is_binary(target_state) do
    case fetch_issue_states_by_ids([issue_id]) do
      {:ok, [current | _]} ->
        cond do
          current.state == target_state ->
            {:already_applied, %{issue_id: issue_id, state: current.state}}

          expected_state not in [nil, :any] and current.state != expected_state ->
            {:conflict, %{issue_id: issue_id, expected_state: expected_state, state: current.state}}

          true ->
            apply_and_verify_projection(issue_id, current.state, target_state)
        end

      {:ok, []} ->
        {:partial_failure, %{issue_id: issue_id, reason: :issue_not_found}}

      {:error, reason} ->
        {:partial_failure, %{issue_id: issue_id, reason: reason}}
    end
  end

  @spec create_pull_request_for_issue(term()) :: {:error, :unsupported_pull_request_creation}
  def create_pull_request_for_issue(_issue), do: {:error, :unsupported_pull_request_creation}

  @spec merge_pull_request(String.t(), String.t()) :: {:error, map()}
  def merge_pull_request(issue_id, expected_head_oid) do
    {:error,
     %{
       stage: :validate,
       reason: {:unsupported_pull_request_merge, issue_id, expected_head_oid}
     }}
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp apply_and_verify_projection(issue_id, previous_state, target_state) do
    with :ok <- update_issue_state(issue_id, target_state),
         {:ok, [verified | _]} <- fetch_issue_states_by_ids([issue_id]),
         true <- verified.state == target_state do
      {:applied, %{issue_id: issue_id, previous_state: previous_state, state: target_state}}
    else
      false -> {:partial_failure, %{issue_id: issue_id, expected_state: target_state, reason: :verification_failed}}
      {:ok, []} -> {:partial_failure, %{issue_id: issue_id, reason: :verification_missing}}
      {:error, reason} -> {:partial_failure, %{issue_id: issue_id, reason: reason}}
    end
  end

  defp linear_comments(response) do
    case get_in(response, ["data", "issue", "comments"]) do
      %{"nodes" => comments, "pageInfo" => page_info} when is_list(comments) and is_map(page_info) ->
        bodies =
          Enum.flat_map(comments, fn
            %{"body" => body} when is_binary(body) -> [body]
            _ -> []
          end)

        {:ok, bodies, page_info}

      _ ->
        {:error, :comment_lookup_failed}
    end
  end

  defp fetch_all_linear_comments(issue_id, before \\ nil, acc \\ []) do
    with {:ok, response} <-
           client_module().graphql(@comments_query, %{issueId: issue_id, before: before}),
         {:ok, comments, page_info} <- linear_comments(response) do
      next_acc = comments ++ acc

      case page_info do
        %{"hasPreviousPage" => true, "startCursor" => cursor}
        when is_binary(cursor) and cursor != "" ->
          fetch_all_linear_comments(issue_id, cursor, next_acc)

        _ ->
          {:ok, next_acc}
      end
    end
  end
end
