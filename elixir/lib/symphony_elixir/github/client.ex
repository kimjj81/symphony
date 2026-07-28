defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST client for polling Issues and Pull Requests as tracker work items.
  """

  require Logger

  alias SymphonyElixir.{Config, HostedGit, Tracker.Issue}

  @per_page 100
  @label_meta %{
    "sym:todo" => {"ededed", "Symphony should triage or prepare this item."},
    "sym:planned" => {"bfd4ff", "Human-approved work ready for Symphony implementation."},
    "sym:in-progress" => {"f9d66d", "Symphony or a human is actively working on this item."},
    "sym:review" => {"0969da", "Ready for Symphony automated review."},
    "sym:reviewing" => {"1f883d", "Symphony automated review is running."},
    "sym:human-review" => {"2da44e", "Waiting for human review or approval."},
    "sym:waiting" => {"6e7781", "Blocked until prerequisite Symphony work is complete."},
    "sym:rework" => {"fb8f44", "Review requested changes for Symphony to address."},
    "sym:reworking" => {"d876e3", "Symphony is actively addressing review findings."},
    "sym:merging" => {"d4c5f9", "Approved work is being merged or finalized."},
    "sym:done" => {"8250df", "Completed successfully."},
    "sym:canceled" => {"8c959f", "Closed without completion."},
    "sym:duplicate" => {"8c959f", "Duplicate work item."}
  }
  @request_label_meta %{
    "sym:request-planned" => {"bfd4ff", "Request that Symphony move this item to Planned."},
    "sym:request-rework" => {"fb8f44", "Request that Symphony move this item to Rework."},
    "sym:request-merging" => {"d4c5f9", "Request that Symphony move this item to Merging."},
    "sym:request-human-review" => {"2da44e", "Request that Symphony move this item to Human Review."},
    "sym:request-canceled" => {"8c959f", "Request that Symphony cancel this item."},
    "sym:request-duplicate" => {"8c959f", "Request that Symphony mark this item duplicate."},
    "sym:request-reopen" => {"bfd4ff", "Request that Symphony reopen this terminal item for human review."}
  }

  @review_threads_query """
  query SymphonyReviewThreads($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        headRefOid
        reviewThreads(first: 100, after: $cursor) {
          nodes {
            id
            isResolved
            comments(last: 100) { nodes { body } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @reply_to_review_thread_mutation """
  mutation SymphonyReplyToReviewThread($input: AddPullRequestReviewThreadReplyInput!) {
    addPullRequestReviewThreadReply(input: $input) { comment { id body } }
  }
  """

  @resolve_review_thread_mutation """
  mutation SymphonyResolveReviewThread($input: ResolveReviewThreadInput!) {
    resolveReviewThread(input: $input) { thread { id isResolved } }
  }
  """
  @spec default_state_labels() :: map()
  def default_state_labels, do: HostedGit.default_state_labels()

  @spec request_labels() :: map()
  def request_labels, do: HostedGit.request_labels()

  @spec managed_label_metadata() :: map()
  def managed_label_metadata, do: Map.merge(@label_meta, @request_label_meta)

  @spec classify_managed_label(String.t()) :: {:request, String.t()} | {:state, String.t()} | :unmanaged
  def classify_managed_label(label) when is_binary(label) do
    HostedGit.classify_managed_label(label, Config.settings!().tracker.state_labels)
  end

  def classify_managed_label(_label), do: :unmanaged

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    Config.settings!().tracker.active_states
    |> fetch_issues_by_states()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    labels =
      state_names
      |> Enum.map(&label_for_state/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    fetch_issues_by_labels(labels)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case fetch_issue_by_id(issue_id) do
        :skip -> {:halt, {:error, :missing_canonical_state}}
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @doc """
  Returns the broker-owned GitHub evidence snapshot for one pull request.

  Opaque review-thread IDs are retained so the worker can describe a closeout
  without receiving tracker credentials or querying GitHub itself.
  """
  @spec fetch_dispatch_snapshot(Issue.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_dispatch_snapshot(%Issue{kind: :issue} = issue), do: {:ok, empty_dispatch_snapshot(issue)}

  def fetch_dispatch_snapshot(%Issue{kind: :pull_request} = issue) do
    with {:ok, snapshot} <- fetch_dispatch_snapshot(issue.id) do
      {:ok, Map.put(snapshot, :work_item, work_item_context(issue))}
    end
  end

  def fetch_dispatch_snapshot(%Issue{} = issue),
    do: {:error, {:unsupported_github_issue_kind, issue.kind}}

  def fetch_dispatch_snapshot(issue_id) when is_binary(issue_id) do
    with {:ok, number, :pull_request} <- parse_issue_id(issue_id),
         {:ok, pull_request} <- request(:get, "/pulls/#{number}"),
         {:ok, live_head} <- pull_request_head(pull_request),
         {:ok, comments} <- fetch_all_comments(number),
         {:ok, reviews} <- fetch_all_reviews(number),
         {:ok, inline_comments} <- fetch_all_inline_comments(number),
         {:ok, tracker} <- github_tracker_config(),
         {:ok, review_snapshot} <- fetch_review_threads(tracker, number) do
      if review_snapshot.head_oid == live_head do
        {:ok,
         %{
           live_head: live_head,
           top_level_comments: Enum.map(comments, &comment_evidence/1),
           reviews: Enum.map(reviews, &review_evidence/1),
           inline_comments: Enum.map(inline_comments, &inline_comment_evidence/1),
           unresolved_feedback:
             review_snapshot.threads
             |> Enum.reject(&(&1["isResolved"] == true))
             |> Enum.map(&review_thread_feedback/1)
         }}
      else
        {:error, {:dispatch_snapshot_head_drift, %{pull_head: live_head, review_head: review_snapshot.head_oid}}}
      end
    else
      {:ok, _number, kind} -> {:error, {:unsupported_github_issue_kind, kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_dispatch_snapshot(_issue_id), do: {:error, :invalid_dispatch_snapshot_issue_id}

  defp empty_dispatch_snapshot(%Issue{} = issue) do
    %{
      work_item: work_item_context(issue),
      live_head: nil,
      top_level_comments: [],
      reviews: [],
      inline_comments: [],
      unresolved_feedback: []
    }
  end

  defp work_item_context(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      url: issue.url,
      kind: issue.kind
    }
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         {:ok, _body} <- request(:post, "/issues/#{number}/comments", json: %{body: body}) do
      :ok
    end
  end

  @doc """
  Creates a broker-owned comment once, using a durable marker embedded in the
  comment body to make journal replay idempotent.
  """
  @spec create_comment_once(String.t(), String.t(), String.t()) :: :applied | :already_applied | {:error, term()}
  def create_comment_once(issue_id, body, marker)
      when is_binary(issue_id) and is_binary(body) and is_binary(marker) and marker != "" do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         {:ok, comments} <- fetch_all_comments(number) do
      if comment_marker_present?(comments, marker) do
        :already_applied
      else
        create_marked_comment(number, body, marker)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_comment_once(_issue_id, _body, _marker), do: {:error, :invalid_comment_marker}

  defp fetch_all_comments(number, page \\ 1, acc \\ []) do
    params = if page == 1, do: %{per_page: 100}, else: %{per_page: 100, page: page}

    case request(:get, "/issues/#{number}/comments", params: params) do
      {:ok, comments} when is_list(comments) and length(comments) == 100 ->
        fetch_all_comments(number, page + 1, acc ++ comments)

      {:ok, comments} when is_list(comments) ->
        {:ok, acc ++ comments}

      {:ok, _payload} ->
        {:error, :github_unexpected_comments_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_reviews(number), do: fetch_paginated("/pulls/#{number}/reviews")

  defp fetch_all_inline_comments(number), do: fetch_paginated("/pulls/#{number}/comments")

  defp fetch_paginated(path, page \\ 1, acc \\ []) do
    params = if page == 1, do: %{per_page: @per_page}, else: %{per_page: @per_page, page: page}

    case request(:get, path, params: params) do
      {:ok, values} when is_list(values) and length(values) == @per_page ->
        fetch_paginated(path, page + 1, acc ++ values)

      {:ok, values} when is_list(values) ->
        {:ok, acc ++ values}

      {:ok, _payload} ->
        {:error, :github_unexpected_paginated_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec sync_webhook_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def sync_webhook_state(event, action, payload)
      when is_binary(event) and is_binary(action) and is_map(payload) do
    case {event, action} do
      {"issues", "labeled"} -> sync_labeled_webhook(:issue, payload)
      {"issues", "closed"} -> sync_closed_issue_webhook(payload)
      {"pull_request", "labeled"} -> sync_labeled_webhook(:pull_request, payload)
      {"pull_request", "closed"} -> sync_closed_pull_request_webhook(payload)
      _ -> :ok
    end
  end

  @doc """
  Adds an open PR to Symphony Rework when a configured Codex review bot creates
  an inline review comment.

  The webhook is intentionally only a dispatch signal. The Rework agent must
  reread the live review threads and decide whether code changes or a justified
  reply are actually required.
  """
  @spec queue_rework_from_review_comment(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def queue_rework_from_review_comment("pull_request_review_comment", "created", payload)
      when is_map(payload) do
    with {:ok, number} <- pull_request_number(payload),
         true <- HostedGit.codex_review_comment?(payload),
         {:ok, raw_issue} <- request(:get, "/issues/#{number}"),
         true <- eligible_pull_request_for_rework?(raw_issue),
         :ok <- update_issue_state(github_issue_id(:pull_request, number), "Rework") do
      Logger.info("Queued Codex inline-review follow-up for GitHub PR ##{number}")
      :ok
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def queue_rework_from_review_comment(_event, _action, _payload), do: :ok

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         target_label when is_binary(target_label) <- label_for_state(state_name),
         {:ok, raw_issue} <- request(:get, "/issues/#{number}"),
         current_labels <- extract_labels(raw_issue),
         {:ok, target_label} <- guarded_target_state_label(number, state_name, target_label),
         :ok <- ensure_label(target_label),
         :ok <- remove_state_labels(number, current_labels),
         {:ok, _body} <- request(:post, "/issues/#{number}/labels", json: %{labels: [target_label]}),
         :ok <- maybe_reopen_guarded_parent(raw_issue, number, state_name, target_label) do
      :ok
    else
      nil -> {:error, {:unknown_github_state, state_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_state_update_failed}
    end
  end

  @doc """
  Projects a state selected by Symphony onto GitHub.

  The expected state is checked against a fresh snapshot before the label set
  is replaced. Non-Symphony labels are preserved, while stale state labels and
  one-shot `sym:request-*` labels are consumed. The replacement is read back so
  callers can distinguish a verified application from a partial external
  effect.
  """
  @spec apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
          {:applied, map()}
          | {:already_applied, map()}
          | {:conflict, map()}
          | {:partial_failure, map()}
  def apply_state_projection(issue_id, expected_state, target_state)
      when is_binary(issue_id) and (is_binary(expected_state) or is_nil(expected_state) or expected_state == :any) and
             is_binary(target_state) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         target_label when is_binary(target_label) <- label_for_state(target_state),
         {:ok, raw_issue} <- request(:get, "/issues/#{number}") do
      labels = extract_labels(raw_issue)

      case projection_snapshot(issue_id, labels) do
        {:ok, snapshot} ->
          number
          |> apply_verified_projection(expected_state, target_state, target_label, snapshot)
          |> finalize_projection_open_state(number, target_state)

        {:error, reason} ->
          {:conflict, %{issue_id: issue_id, expected_state: expected_state, reason: reason, labels: labels}}
      end
    else
      nil -> {:partial_failure, %{stage: :validate, reason: {:unknown_github_state, target_state}}}
      {:error, reason} -> {:partial_failure, %{stage: :read, reason: reason}}
      other -> {:partial_failure, %{stage: :validate, reason: other}}
    end
  end

  @doc """
  Merges a pull request only when its live head matches the orchestrator's
  expected head OID. The guarded GitHub merge request is brokered here so a
  worker never needs tracker write credentials.
  """
  @spec merge_pull_request(String.t(), String.t()) :: {:applied, map()} | {:conflict, map()} | {:error, map()}
  def merge_pull_request(issue_id, expected_head_oid)
      when is_binary(issue_id) and is_binary(expected_head_oid) and expected_head_oid != "" do
    with {:ok, number, :pull_request} <- parse_issue_id(issue_id),
         {:ok, pull_request} <- request(:get, "/pulls/#{number}") do
      apply_guarded_merge(issue_id, number, expected_head_oid, pull_request)
    else
      {:ok, _number, kind} -> {:error, %{stage: :validate, reason: {:unsupported_github_issue_kind, kind}}}
      {:error, reason} -> {:error, %{stage: :read, reason: reason}}
    end
  end

  def merge_pull_request(issue_id, expected_head_oid),
    do: {:error, %{stage: :validate, reason: {:invalid_merge_request, issue_id, expected_head_oid}}}

  @doc """
  Applies the broker-owned closeout for a published rework head. The worker
  provides only opaque thread references and Korean reply text; this client
  re-reads GitHub before writing so stale or newly-added feedback cannot be
  silently closed.
  """
  @spec close_review_threads(String.t(), String.t(), [map()], String.t()) ::
          {:applied, map()} | {:handoff, term(), map()} | {:retry, term(), map()} | {:conflict, map()}
  def close_review_threads(issue_id, expected_head_oid, updates, marker)
      when is_binary(issue_id) and is_binary(expected_head_oid) and expected_head_oid != "" and is_list(updates) and
             is_binary(marker) and marker != "" do
    with {:ok, number, :pull_request} <- parse_issue_id(issue_id),
         {:ok, tracker} <- github_tracker_config(),
         {:ok, snapshot} <- fetch_review_threads(tracker, number),
         :ok <- validate_review_thread_snapshot(snapshot, expected_head_oid, updates) do
      apply_review_thread_updates(snapshot.threads, updates, marker, tracker, number, expected_head_oid)
    else
      {:ok, _number, kind} -> {:conflict, %{issue_id: issue_id, reason: {:unsupported_github_issue_kind, kind}}}
      {:error, reason} -> {:retry, reason, %{issue_id: issue_id, expected_head_oid: expected_head_oid}}
      {:conflict, reason} -> {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, reason: reason}}
    end
  end

  def close_review_threads(issue_id, expected_head_oid, _updates, _marker),
    do: invalid_review_thread_closeout(issue_id, expected_head_oid)

  @spec create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def create_pull_request_for_issue(%Issue{kind: :issue} = issue) do
    case parse_issue_id(issue.id) do
      {:ok, number, :issue} ->
        create_pull_request_for_issue_number(issue, number)

      {:ok, _number, kind} ->
        {:error, {:unsupported_github_issue_kind, kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_pull_request_for_issue(%Issue{kind: kind}), do: {:error, {:unsupported_github_issue_kind, kind}}

  @doc false
  @spec normalize_issue_for_test(map()) :: {:ok, Issue.t()} | :skip | {:error, term()}
  def normalize_issue_for_test(raw_issue) when is_map(raw_issue) do
    normalize_issue(raw_issue)
  end

  @doc false
  @spec state_from_labels_for_test([String.t()]) :: {:ok, String.t() | nil} | {:error, term()}
  def state_from_labels_for_test(labels) when is_list(labels) do
    state_from_labels(labels)
  end

  @doc false
  @spec collect_issues_matching_labels_for_test([String.t()], (-> {:ok, term()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def collect_issues_matching_labels_for_test(labels, issue_lister)
      when is_list(labels) and is_function(issue_lister, 0) do
    collect_issues_matching_labels(labels, issue_lister)
  end

  defp fetch_issues_by_labels([]), do: {:ok, []}

  defp fetch_issues_by_labels(labels) do
    labels
    |> collect_issues_matching_labels()
    |> normalize_issues_for_labels()
  end

  defp collect_issues_matching_labels(labels) do
    collect_issues_matching_labels(labels, fn -> search_issues_for_labels(labels) end)
  end

  defp collect_issues_matching_labels(labels, issue_lister) do
    case issue_lister.() do
      {:ok, issues} when is_list(issues) ->
        {:ok, filter_issues_by_labels(issues, labels)}

      {:ok, _payload} ->
        {:error, :github_unexpected_issues_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_issues_by_labels(issues, labels) do
    desired_labels =
      labels
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    Enum.filter(issues, fn issue ->
      issue
      |> extract_labels()
      |> Enum.any?(fn label -> MapSet.member?(desired_labels, normalize_label(label)) end)
    end)
  end

  defp normalize_issues_for_labels({:ok, issues}) do
    issues
    |> Enum.reduce_while({:ok, []}, &normalize_issue_for_labels/2)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> unique_issues()}
      error -> error
    end
  end

  defp normalize_issues_for_labels(error), do: error

  defp normalize_issue_for_labels(raw_issue, {:ok, acc}) do
    case normalize_issue(raw_issue) do
      {:ok, issue} ->
        {:cont, {:ok, [issue | acc]}}

      :skip ->
        {:cont, {:ok, acc}}

      {:error, {:ambiguous_state_labels, states}} ->
        Logger.warning("Skipping GitHub candidate with ambiguous Symphony state labels number=#{inspect(raw_issue["number"])} states=#{inspect(states)}")

        {:cont, {:ok, acc}}
    end
  end

  defp search_issues_for_labels(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
      case search_issues_for_label(label) do
        {:ok, issues} -> {:cont, {:ok, issues ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp search_issues_for_label(label), do: search_issues_for_label(label, 1, [])

  defp search_issues_for_label(label, page, acc) do
    case request(:get, "/search/issues", params: %{q: search_query_for_label(label), per_page: @per_page, page: page}) do
      {:ok, %{"items" => issues}} when is_list(issues) ->
        next_acc = acc ++ issues

        if length(issues) == @per_page do
          search_issues_for_label(label, page + 1, next_acc)
        else
          {:ok, next_acc}
        end

      {:ok, _payload} ->
        {:error, :github_unexpected_issues_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue_by_id(issue_id) do
    with {:ok, number, expected_kind} <- parse_issue_id(issue_id),
         {:ok, raw_issue} <- request(:get, "/issues/#{number}"),
         {:ok, pull_data} <- fetch_pull_data(number, expected_kind, raw_issue) do
      normalize_issue(raw_issue, pull_data)
    end
  end

  defp fetch_pull_data(number, expected_kind, raw_issue) do
    if pull_data_required?(expected_kind, raw_issue),
      do: request(:get, "/pulls/#{number}"),
      else: {:ok, nil}
  end

  defp pull_data_required?(expected_kind, raw_issue) do
    expected_kind == :pull_request or Map.has_key?(raw_issue, "pull_request")
  end

  defp fetch_pull(number) do
    case request(:get, "/pulls/#{number}") do
      {:ok, pull} -> pull
      {:error, _reason} -> nil
    end
  end

  defp pull_request_number(%{"pull_request" => %{"number" => number}}),
    do: normalize_github_number(number)

  defp pull_request_number(_payload), do: {:error, :github_pull_request_number_missing}

  defp eligible_pull_request_for_rework?(raw_issue) when is_map(raw_issue) do
    Map.get(raw_issue, "state") == "open" and
      issue_kind(raw_issue) == :pull_request and
      not label_present?(extract_labels(raw_issue), label_for_state("Rework"))
  end

  defp eligible_pull_request_for_rework?(_raw_issue), do: false

  defp normalize_issue(raw_issue, pull_data \\ nil) when is_map(raw_issue) do
    labels = extract_labels(raw_issue)

    case state_from_labels(labels) do
      {:ok, state} ->
        state = state_for_physical_item_state(raw_issue, pull_data, state)

        if is_nil(state) do
          :skip
        else
          number = raw_issue["number"]
          kind = issue_kind(raw_issue)

          {:ok,
           %Issue{
             id: github_issue_id(kind, number),
             identifier: github_identifier(kind, number),
             title: raw_issue["title"],
             description: raw_issue["body"],
             priority: nil,
             state: state,
             branch_name: pull_branch_name(pull_data),
             url: raw_issue["html_url"],
             assignee_id: assignee_id(raw_issue["assignee"]),
             kind: kind,
             metadata: %{
               tracker: "github",
               number: number,
               repository: github_repository(),
               node_id: raw_issue["node_id"],
               physical_state: raw_issue["state"],
               merged: pull_merged?(pull_data),
               head_oid: get_in(pull_data || %{}, ["head", "sha"])
             },
             labels: labels,
             assigned_to_worker: true,
             created_at: parse_datetime(raw_issue["created_at"]),
             updated_at: parse_datetime(raw_issue["updated_at"])
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_from_labels(labels) when is_list(labels) do
    label_to_state = label_to_state_map()

    matches =
      labels
      |> Enum.map(&normalize_label/1)
      |> Enum.filter(&Map.has_key?(label_to_state, &1))
      |> Enum.map(&Map.fetch!(label_to_state, &1))
      |> Enum.uniq()

    case matches do
      [] -> {:ok, nil}
      [state] -> {:ok, state}
      states -> {:error, {:ambiguous_state_labels, states}}
    end
  end

  defp fallback_closed_state(%{"state" => "closed"} = raw_issue, pull_data) do
    if issue_kind(raw_issue) == :pull_request and pull_merged?(pull_data),
      do: "Done",
      else: "Canceled"
  end

  defp fallback_closed_state(_raw_issue, _pull_data), do: nil

  defp state_for_physical_item_state(%{"state" => "closed"} = raw_issue, pull_data, state) do
    if terminal_issue_state_reason(state),
      do: state,
      else: fallback_closed_state(raw_issue, pull_data)
  end

  defp state_for_physical_item_state(_raw_issue, _pull_data, state), do: state

  defp sync_labeled_webhook(_kind, %{"sender" => %{"login" => "github-actions[bot]"}}), do: :ok

  defp sync_labeled_webhook(kind, payload) when kind in [:issue, :pull_request] do
    label = get_in(payload, ["label", "name"])

    with state_name when is_binary(state_name) <- state_for_label(label),
         {:ok, number} <- webhook_issue_number(kind, payload),
         {:ok, labels} <- current_labels(number) do
      sync_labeled_state(kind, number, label, labels, state_name)
    else
      nil -> :ok
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_labeled_state(kind, number, label, labels, state_name) do
    if label_present?(labels, label) do
      with :ok <- set_state_label(number, label, labels, remove_target?: false) do
        maybe_sync_labeled_issue_open_state(kind, number, state_name)
      end
    else
      :ok
    end
  end

  defp maybe_sync_labeled_issue_open_state(:issue, number, state_name), do: sync_issue_and_parent_open_state(number, state_name)
  defp maybe_sync_labeled_issue_open_state(_kind, _number, _state_name), do: :ok

  defp sync_closed_issue_webhook(payload) do
    with {:ok, number} <- webhook_issue_number(:issue, payload),
         state_name <- closed_issue_state_name(payload),
         target_label when is_binary(target_label) <- label_for_state(state_name),
         {:ok, labels} <- current_labels(number),
         :ok <- set_state_label(number, target_label, labels, remove_target?: false) do
      sync_issue_and_parent_open_state(number, state_name)
    else
      nil -> :ok
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_closed_pull_request_webhook(payload) do
    state_name = if get_in(payload, ["pull_request", "merged"]) == true, do: "Done", else: "Canceled"

    with target_label when is_binary(target_label) <- label_for_state(state_name),
         {:ok, number} <- webhook_issue_number(:pull_request, payload),
         {:ok, labels} <- current_labels(number) do
      set_state_label(number, target_label, labels, remove_target?: false)
    else
      nil -> :ok
      :skip -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_issue_and_parent_open_state(number, state_name) do
    with :ok <- sync_issue_open_state(number, state_name) do
      maybe_sync_parent_issue_after_child_state(number, state_name)
    end
  end

  defp sync_issue_open_state(number, state_name) do
    with {:ok, issue} <- request(:get, "/issues/#{number}") do
      sync_issue_open_state_for_target(number, issue, state_name)
    end
  end

  defp sync_issue_open_state_for_target(number, issue, state_name) do
    case terminal_issue_state_reason(state_name) do
      reason when is_binary(reason) -> sync_terminal_issue_open_state(number, issue, reason)
      nil -> maybe_reopen_issue(number, issue)
    end
  end

  defp sync_terminal_issue_open_state(number, issue, reason) do
    case parent_issue_terminal_guard(number) do
      :allow -> maybe_update_issue_open_state(issue, number, "closed", reason)
      :defer -> keep_issue_in_human_review(number, issue)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_reopen_issue(number, issue) do
    if issue["state"] == "closed" do
      update_issue(number, %{state: "open"})
    else
      :ok
    end
  end

  defp maybe_sync_parent_issue_after_child_state(number, state_name) do
    case terminal_issue_state_reason(state_name) do
      nil -> :ok
      _reason -> sync_parent_issue_after_terminal_child(number)
    end
  end

  defp sync_parent_issue_after_terminal_child(number) do
    case fetch_parent_issue_number(number) do
      {:ok, parent_number} when is_integer(parent_number) -> sync_parent_issue_from_sub_issues(parent_number)
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_parent_issue_from_sub_issues(parent_number) when is_integer(parent_number) do
    with {:ok, issue} <- request(:get, "/issues/#{parent_number}") do
      sync_parent_issue_from_guard(parent_number, issue, parent_issue_terminal_guard(parent_number))
    end
  end

  defp sync_parent_issue_from_guard(parent_number, issue, :allow), do: mark_parent_issue_done(parent_number, issue)
  defp sync_parent_issue_from_guard(parent_number, issue, :defer), do: keep_issue_in_human_review(parent_number, issue)
  defp sync_parent_issue_from_guard(_parent_number, _issue, {:error, reason}), do: {:error, reason}

  defp mark_parent_issue_done(parent_number, issue) do
    with {:ok, labels} <- current_labels(parent_number),
         target_label when is_binary(target_label) <- label_for_state("Done"),
         :ok <- set_state_label(parent_number, target_label, labels, remove_target?: false) do
      maybe_update_issue_open_state(issue, parent_number, "closed", "completed")
    end
  end

  defp parent_issue_terminal_guard(number) when is_integer(number) do
    with {:ok, sub_issues} <- fetch_sub_issues(number) do
      cond do
        sub_issues == [] -> :allow
        Enum.all?(sub_issues, &terminal_sub_issue?/1) -> :allow
        true -> :defer
      end
    end
  end

  defp terminal_sub_issue?(raw_issue) when is_map(raw_issue) do
    state =
      case state_from_labels(extract_labels(raw_issue)) do
        {:ok, state} -> state || fallback_closed_state(raw_issue, nil)
        {:error, _reason} -> nil
      end

    not is_nil(state) and terminal_issue_state_reason(state) != nil
  end

  defp keep_issue_in_human_review(number, issue) when is_integer(number) and is_map(issue) do
    with {:ok, labels} <- current_labels(number),
         target_label when is_binary(target_label) <- label_for_state("Human Review"),
         :ok <- set_state_label(number, target_label, labels, remove_target?: true) do
      if issue["state"] == "closed" do
        update_issue(number, %{state: "open"})
      else
        :ok
      end
    end
  end

  defp guarded_target_state_label(number, state_name, target_label) when is_integer(number) do
    if terminal_issue_state_reason(state_name) do
      case parent_issue_terminal_guard(number) do
        :allow -> {:ok, target_label}
        :defer -> {:ok, label_for_state("Human Review")}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, target_label}
    end
  end

  defp maybe_reopen_guarded_parent(issue, number, state_name, target_label) do
    if terminal_issue_state_reason(state_name) && target_label == label_for_state("Human Review") &&
         issue["state"] == "closed" do
      update_issue(number, %{state: "open"})
    else
      :ok
    end
  end

  defp maybe_update_issue_open_state(issue, number, target_state, state_reason) do
    if issue["state"] == target_state and issue["state_reason"] == state_reason do
      :ok
    else
      update_issue(number, %{state: target_state, state_reason: state_reason})
    end
  end

  defp update_issue(number, json) when is_integer(number) and is_map(json) do
    case request(:patch, "/issues/#{number}", json: json) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_state_label(number, target_label, current_labels, opts) do
    remove_target? = Keyword.get(opts, :remove_target?, true)

    with :ok <- ensure_label(target_label),
         :ok <- remove_state_labels(number, current_labels, target_label, remove_target?) do
      maybe_add_label(number, current_labels, target_label, remove_target?)
    end
  end

  defp maybe_add_label(number, current_labels, target_label, remove_target?) do
    if remove_target? or not label_present?(current_labels, target_label) do
      case request(:post, "/issues/#{number}/labels", json: %{labels: [target_label]}) do
        {:ok, _body} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp current_labels(number) when is_integer(number) do
    case request(:get, "/issues/#{number}/labels", params: %{per_page: 100}) do
      {:ok, labels} when is_list(labels) -> {:ok, extract_labels(%{"labels" => labels})}
      {:ok, _payload} -> {:error, :github_unexpected_labels_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp projection_snapshot(issue_id, labels) do
    case state_from_labels(labels) do
      {:ok, state} -> {:ok, %{issue_id: issue_id, state: state, labels: labels}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp comment_marker_present?(comments, marker) when is_list(comments) do
    Enum.any?(comments, fn
      %{"body" => body} when is_binary(body) -> String.contains?(body, marker)
      _ -> false
    end)
  end

  defp comment_marker_present?(_comments, _marker), do: false

  defp create_marked_comment(number, body, marker) do
    marked_body = if String.contains?(body, marker), do: body, else: body <> "\n\n" <> marker

    case request(:post, "/issues/#{number}/comments", json: %{body: marked_body}) do
      {:ok, _body} -> :applied
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_guarded_merge(issue_id, _number, _expected_head_oid, %{"merged" => true} = pull_request) do
    {:applied,
     %{
       issue_id: issue_id,
       merged: true,
       already_applied: true,
       head_oid: get_in(pull_request, ["head", "sha"]),
       merge_commit_sha: pull_request["merge_commit_sha"]
     }}
  end

  defp apply_guarded_merge(issue_id, number, expected_head_oid, pull_request) do
    current_head_oid = get_in(pull_request, ["head", "sha"])

    if current_head_oid == expected_head_oid do
      case request(:put, "/pulls/#{number}/merge", json: %{sha: expected_head_oid, merge_method: "squash"}) do
        {:ok, %{"merged" => true} = body} ->
          {:applied,
           %{
             issue_id: issue_id,
             merged: true,
             already_applied: false,
             head_oid: expected_head_oid,
             merge_commit_sha: body["sha"]
           }}

        {:ok, body} ->
          {:error, %{stage: :merge, reason: {:github_merge_rejected, body}}}

        {:error, {:github_api_status, 409, body}} ->
          {:conflict,
           %{
             issue_id: issue_id,
             expected_head_oid: expected_head_oid,
             current_head_oid: current_head_oid,
             reason: body
           }}

        {:error, reason} ->
          {:error, %{stage: :merge, reason: reason}}
      end
    else
      {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, current_head_oid: current_head_oid}}
    end
  end

  defp apply_verified_projection(number, expected_state, target_state, target_label, snapshot) do
    desired_labels = projected_labels(snapshot.labels, target_label)

    cond do
      expected_state_matches?(target_state, snapshot.state) and
          same_label_set?(snapshot.labels, desired_labels) ->
        {:already_applied, %{snapshot | state: target_state, labels: desired_labels}}

      expected_state_matches?(target_state, snapshot.state) ->
        write_and_verify_projection(number, target_state, target_label, desired_labels, snapshot)

      expected_state_matches?(expected_state, snapshot.state) ->
        write_and_verify_projection(number, target_state, target_label, desired_labels, snapshot)

      true ->
        {:conflict, Map.merge(snapshot, %{expected_state: expected_state, target_state: target_state})}
    end
  end

  defp write_and_verify_projection(number, target_state, target_label, desired_labels, snapshot) do
    with :ok <- ensure_label(target_label),
         {:ok, _body} <- request(:put, "/issues/#{number}/labels", json: %{labels: desired_labels}),
         {:ok, verified_labels} <- current_labels(number),
         true <- same_label_set?(verified_labels, desired_labels),
         {:ok, observed_state} <- state_from_labels(verified_labels),
         true <- expected_state_matches?(target_state, observed_state) do
      {:applied, %{snapshot | state: target_state, labels: verified_labels}}
    else
      {:error, reason} ->
        {:partial_failure, %{stage: projection_failure_stage(reason), reason: reason, before: snapshot}}

      false ->
        {:partial_failure, %{stage: :verify, reason: :github_projection_mismatch, before: snapshot}}
    end
  end

  defp finalize_projection_open_state({status, metadata}, number, target_state)
       when status in [:applied, :already_applied] do
    with :ok <- sync_issue_open_state(number, target_state),
         {:ok, issue} <- request(:get, "/issues/#{number}"),
         :ok <- verify_projected_open_state(issue, target_state) do
      {status, Map.put(metadata, :open_state, issue["state"])}
    else
      {:error, reason} ->
        {:partial_failure, %{stage: :open_state_projection, reason: reason, projection: metadata}}
    end
  end

  defp finalize_projection_open_state(result, _number, _target_state), do: result

  defp verify_projected_open_state(issue, target_state) do
    expected_state = if terminal_issue_state_reason(target_state), do: "closed", else: "open"

    if issue["state"] == expected_state,
      do: :ok,
      else: {:error, {:github_open_state_mismatch, expected_state, issue["state"]}}
  end

  defp projected_labels(current_labels, target_label) do
    managed_labels =
      state_label_map()
      |> Map.values()
      |> Kernel.++(Map.keys(HostedGit.request_labels()))
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    current_labels
    |> Enum.reject(&MapSet.member?(managed_labels, normalize_label(&1)))
    |> Kernel.++([target_label])
    |> Enum.uniq_by(&normalize_label/1)
  end

  defp expected_state_matches?(:any, _current_state), do: true
  defp expected_state_matches?(nil, nil), do: true

  defp expected_state_matches?(expected_state, current_state)
       when is_binary(expected_state) and is_binary(current_state),
       do: normalize_state(expected_state) == normalize_state(current_state)

  defp expected_state_matches?(_expected_state, _current_state), do: false

  defp same_label_set?(left, right) do
    normalize_label_set(left) == normalize_label_set(right)
  end

  defp normalize_label_set(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> MapSet.new()
  end

  defp projection_failure_stage({:github_api_status, _, _}), do: :projection_write_or_verify
  defp projection_failure_stage({:github_retryable_api_status, _, _}), do: :projection_write_or_verify
  defp projection_failure_stage({:github_api_request, _}), do: :projection_write_or_verify
  defp projection_failure_stage(_reason), do: :prepare

  defp fetch_sub_issues(number) when is_integer(number) do
    case request(:get, "/issues/#{number}/sub_issues", params: %{per_page: 100}) do
      {:ok, sub_issues} when is_list(sub_issues) ->
        {:ok, sub_issues}

      {:ok, _payload} ->
        {:error, :github_unexpected_sub_issues_payload}

      {:error, {:github_api_status, status, _body}} when status in [404, 410] ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_parent_issue_number(number) when is_integer(number) do
    case request(:get, "/issues/#{number}/parent") do
      {:ok, %{"number" => parent_number}} when is_integer(parent_number) -> {:ok, parent_number}
      {:ok, nil} -> {:ok, nil}
      {:ok, _payload} -> {:error, :github_unexpected_parent_issue_payload}
      {:error, {:github_api_status, status, _body}} when status in [404, 410] -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_state_labels(number, current_labels) do
    remove_state_labels(number, current_labels, nil, true)
  end

  defp remove_state_labels(number, current_labels, target_label, remove_target?) do
    managed_label_set =
      (Map.values(state_label_map()) ++
         Map.values(Config.settings!().state_manager.human_intent_labels))
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    current_labels
    |> Enum.filter(fn label ->
      state_label? = MapSet.member?(managed_label_set, normalize_label(label))
      target_label? = not is_nil(target_label) and normalize_label(label) == normalize_label(target_label)
      state_label? and (remove_target? or not target_label?)
    end)
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case request(:delete, "/issues/#{number}/labels/#{URI.encode_www_form(label)}") do
        {:ok, _body} -> {:cont, :ok}
        {:error, {:github_api_status, 404, _body}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp terminal_issue_state_reason(state_name) do
    case normalize_state(state_name) do
      "done" -> "completed"
      state when state in ["canceled", "duplicate"] -> "not_planned"
      _ -> nil
    end
  end

  defp closed_issue_state_name(payload) do
    case get_in(payload, ["issue", "state_reason"]) do
      "duplicate" -> "Duplicate"
      "not_planned" -> "Canceled"
      _ -> "Done"
    end
  end

  defp webhook_issue_number(:issue, payload) do
    payload
    |> get_in(["issue", "number"])
    |> fallback_value(Map.get(payload, "number"))
    |> normalize_github_number()
  end

  defp webhook_issue_number(:pull_request, payload) do
    payload
    |> get_in(["pull_request", "number"])
    |> fallback_value(Map.get(payload, "number"))
    |> normalize_github_number()
  end

  defp fallback_value(nil, fallback), do: fallback
  defp fallback_value(value, _fallback), do: value

  defp normalize_github_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp normalize_github_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :skip
    end
  end

  defp normalize_github_number(_number), do: :skip

  defp ensure_label(label) when is_binary(label) do
    case request(:get, "/labels/#{URI.encode_www_form(label)}") do
      {:ok, _body} ->
        :ok

      {:error, {:github_api_status, 404, _body}} ->
        {color, description} = Map.get(managed_label_metadata(), label, {"ededed", "Symphony workflow state."})

        case request(:post, "/labels", json: %{name: label, color: color, description: description}) do
          {:ok, _body} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_open_pull_request_for_branch(branch, desired_state) when is_binary(branch) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, pulls} <-
           request(:get, "/pulls", params: %{state: "open", head: "#{tracker.owner}:#{branch}", per_page: 1}) do
      case pulls do
        [%{"number" => number} | _] when is_integer(number) ->
          fetch_visible_or_plan_pull_request("github:pr:#{number}", desired_state)

        [] ->
          {:ok, nil}

        _ ->
          {:error, :github_unexpected_pulls_payload}
      end
    end
  end

  defp fetch_pull_request_status_for_branch(branch) when is_binary(branch) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, pulls} <-
           request(:get, "/pulls", params: %{state: "all", head: "#{tracker.owner}:#{branch}", per_page: 1}) do
      case pulls do
        [%{"number" => number} = pull | _] when is_integer(number) ->
          pull_data = fetch_pull(number)
          {:ok, %{state: pull["state"], merged?: pull_merged?(pull_data)}}

        [] ->
          {:ok, nil}

        _ ->
          {:error, :github_unexpected_pulls_payload}
      end
    end
  end

  defp fetch_visible_or_plan_pull_request(issue_id, desired_state) do
    case fetch_issue_by_id(issue_id) do
      {:ok, %Issue{} = issue} ->
        {:ok, issue}

      :skip ->
        with :ok <- update_issue_state(issue_id, desired_state) do
          fetch_visible_issue_by_id(issue_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_pull_request_for_issue_number(%Issue{} = issue, number) when is_integer(number) do
    with {:ok, sub_issues} <- fetch_sub_issues(number) do
      create_pull_request_for_issue_sub_issues(issue, number, sub_issues)
    end
  end

  defp create_pull_request_for_issue_sub_issues(_issue, parent_number, sub_issues)
       when is_list(sub_issues) and sub_issues != [] do
    case first_planned_sub_issue(sub_issues) do
      {:ok, %Issue{} = sub_issue, sub_issue_number} ->
        with {:ok, specs} <- issue_pull_request_specs(sub_issue_number, sub_issue, parent_number: parent_number) do
          create_issue_pull_requests(sub_issue, specs)
        end

      :none ->
        {:error, {:github_no_planned_sub_issue, parent_number}}
    end
  end

  defp create_pull_request_for_issue_sub_issues(%Issue{} = issue, number, []) do
    with {:ok, parent_number} <- fetch_parent_issue_number(number) do
      with {:ok, specs} <- issue_pull_request_specs(number, issue, parent_number: parent_number) do
        create_issue_pull_requests(issue, specs)
      end
    end
  end

  defp first_planned_sub_issue(sub_issues) when is_list(sub_issues) do
    Enum.find_value(sub_issues, :none, fn raw_issue ->
      with true <- raw_issue["state"] != "closed",
           {:ok, "Planned"} <- raw_issue |> extract_labels() |> state_from_labels(),
           number when is_integer(number) <- raw_issue["number"],
           {:ok, %Issue{} = issue} <- normalize_issue(raw_issue) do
        {:ok, issue, number}
      else
        _ -> false
      end
    end)
  end

  defp create_issue_pull_requests(issue, specs) when is_list(specs) and specs != [] do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case fetch_or_create_issue_pull_request(issue, spec) do
        {:ok, %Issue{} = pull_request} -> {:cont, {:ok, [pull_request | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pull_requests} when pull_requests != [] ->
        pull_requests = Enum.reverse(pull_requests)
        {:ok, Enum.find(pull_requests, List.first(pull_requests), &(!Map.get(&1.metadata || %{}, :integration_pull_request?, false)))}

      {:ok, []} ->
        {:error, :github_pull_request_creation_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_or_create_issue_pull_request(issue, %{branch: branch} = spec) do
    case fetch_open_pull_request_for_branch(branch, Map.get(spec, :state, "Planned")) do
      {:ok, %Issue{} = pull_request} ->
        {:ok, maybe_mark_integration_pull_request(pull_request, spec)}

      {:ok, nil} ->
        create_issue_pull_request(issue, spec)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_issue_pull_request(issue, %{number: number, branch: branch} = spec) do
    with {:ok, default_base_branch} <- pull_request_base_branch(),
         base_branch <- Map.get(spec, :base_branch, default_base_branch),
         branch_base <- Map.get(spec, :branch_base, base_branch),
         :ok <- ensure_issue_feature_branch(issue, number, spec, default_base_branch),
         {:ok, _branch_sha} <- ensure_issue_pull_request_branch(issue, number, branch, branch_base),
         {:ok, raw_pull_request} <-
           request(:post, "/pulls",
             json: %{
               title: issue_pull_request_title(issue, spec),
               head: branch,
               base: base_branch,
               body: issue_pull_request_body(issue, spec),
               draft: false
             }
           ),
         pull_number when is_integer(pull_number) <- raw_pull_request["number"],
         pull_request_id <- "github:pr:#{pull_number}",
         :ok <- update_issue_state(pull_request_id, Map.get(spec, :state, "Planned")) do
      with {:ok, %Issue{} = pull_request} <- fetch_visible_issue_by_id(pull_request_id) do
        {:ok, maybe_mark_integration_pull_request(pull_request, spec)}
      end
    else
      {:error, {:github_api_status, 422, _body}} ->
        case fetch_open_pull_request_for_branch(branch, Map.get(spec, :state, "Planned")) do
          {:ok, %Issue{} = pull_request} -> {:ok, maybe_mark_integration_pull_request(pull_request, spec)}
          {:ok, nil} -> {:error, :github_pull_request_creation_failed}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :github_pull_request_number_missing}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_pull_request_creation_failed}
    end
  end

  defp ensure_issue_feature_branch(issue, number, %{feature_branch: feature_branch}, base_branch)
       when is_binary(feature_branch) do
    case ensure_issue_pull_request_branch(issue, number, feature_branch, base_branch) do
      {:ok, _branch_sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_issue_feature_branch(_issue, _number, _spec, _base_branch), do: :ok

  defp ensure_issue_pull_request_branch(issue, number, branch, base_branch) do
    case fetch_branch_sha(branch) do
      {:ok, branch_sha} ->
        {:ok, branch_sha}

      {:error, {:github_api_status, 404, _body}} ->
        with {:ok, base_sha} <- fetch_branch_sha(base_branch),
             {:ok, tree_sha} <- fetch_commit_tree_sha(base_sha),
             {:ok, commit_sha} <- create_issue_pull_request_commit(issue, number, base_sha, tree_sha),
             :ok <- create_branch_ref(branch, commit_sha) do
          {:ok, commit_sha}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_branch_sha(branch) when is_binary(branch) do
    case request(:get, "/git/ref/heads/#{branch}") do
      {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, _payload} -> {:error, :github_unexpected_ref_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_commit_tree_sha(commit_sha) when is_binary(commit_sha) do
    case request(:get, "/git/commits/#{commit_sha}") do
      {:ok, %{"tree" => %{"sha" => tree_sha}}} when is_binary(tree_sha) -> {:ok, tree_sha}
      {:ok, _payload} -> {:error, :github_unexpected_commit_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_issue_pull_request_commit(issue, number, base_sha, tree_sha) do
    case request(:post, "/git/commits",
           json: %{
             message: "chore: prepare issue ##{number} implementation PR",
             tree: tree_sha,
             parents: [base_sha],
             author: %{
               name: "Symphony",
               email: "symphony@users.noreply.github.com"
             }
           }
         ) do
      {:ok, %{"sha" => sha}} when is_binary(sha) ->
        {:ok, sha}

      {:ok, _payload} ->
        {:error, :github_unexpected_commit_create_payload}

      {:error, reason} ->
        Logger.warning("Failed to create empty PR commit for #{inspect(issue.identifier)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_branch_ref(branch, sha) when is_binary(branch) and is_binary(sha) do
    case request(:post, "/git/refs", json: %{ref: "refs/heads/#{branch}", sha: sha}) do
      {:ok, _payload} -> :ok
      {:error, {:github_api_status, 422, _body}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_visible_issue_by_id(issue_id) do
    case fetch_issue_by_id(issue_id) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      :skip -> {:error, {:github_issue_not_visible, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pull_request_base_branch do
    base_ref =
      Config.settings!().workspace.base_ref
      |> to_string()
      |> String.trim()

    cond do
      base_ref == "" or base_ref == "HEAD" ->
        default_branch()

      String.starts_with?(base_ref, "origin/") ->
        {:ok, String.replace_prefix(base_ref, "origin/", "")}

      String.starts_with?(base_ref, "refs/heads/") ->
        {:ok, String.replace_prefix(base_ref, "refs/heads/", "")}

      true ->
        {:ok, base_ref}
    end
  end

  defp default_branch do
    case request(:get, "") do
      {:ok, %{"default_branch" => branch}} when is_binary(branch) and branch != "" -> {:ok, branch}
      {:ok, _payload} -> {:error, :github_default_branch_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_pull_request_specs(number, %Issue{} = issue, opts) when is_integer(number) do
    sections = HostedGit.pull_request_sections(issue.description || "")
    parent_number = Keyword.get(opts, :parent_number)

    if length(sections) >= 2 do
      feature_branch = issue_feature_branch(number)

      all_specs =
        Enum.map(sections, fn section ->
          %{
            number: number,
            branch: "symphony/_#{number}-pr#{section.number}",
            base_branch: feature_branch,
            branch_base: feature_branch,
            feature_branch: feature_branch,
            split?: true,
            section: section,
            followups: Enum.reject(sections, &(&1.number == section.number)),
            parent_number: parent_number
          }
        end)

      child_specs =
        if HostedGit.parallel_pull_request_plan?(issue.description || "") do
          {:ok, all_specs}
        else
          sequential_split_child_specs(number, all_specs)
        end

      case child_specs do
        {:ok, child_specs} ->
          {:ok, [integration_pull_request_spec(number, feature_branch, sections, parent_number)] ++ child_specs}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok,
       [
         %{
           number: number,
           branch: issue_pull_request_branch(number),
           split?: false,
           section: nil,
           followups: [],
           parent_number: parent_number
         }
       ]}
    end
  end

  defp issue_pull_request_branch(number) when is_integer(number), do: "symphony/_#{number}"

  defp issue_feature_branch(number) when is_integer(number), do: "symphony/_#{number}-feature"

  defp sequential_split_child_specs(number, all_specs) do
    case requested_split_child_spec(number, all_specs) do
      {:ok, %{} = spec} -> {:ok, [spec]}
      {:error, reason} -> {:error, reason}
      :none -> first_unmerged_split_child_specs(all_specs)
    end
  end

  defp requested_split_child_spec(number, all_specs) do
    case requested_split_pr_number(number) do
      pr_number when is_integer(pr_number) -> requested_split_child_spec_for_pr(pr_number, all_specs)
      nil -> :none
    end
  end

  defp requested_split_child_spec_for_pr(pr_number, all_specs) do
    all_specs
    |> Enum.find(&(&1.section.number == pr_number))
    |> maybe_requested_split_child_spec()
  end

  defp maybe_requested_split_child_spec(nil), do: :none

  defp maybe_requested_split_child_spec(spec) do
    case split_child_merged?(spec) do
      {:ok, true} -> :none
      {:ok, false} -> {:ok, spec}
      {:error, reason} -> {:error, reason}
    end
  end

  defp requested_split_pr_number(number) when is_integer(number) do
    case request(:get, "/issues/#{number}/comments", params: %{per_page: 100}) do
      {:ok, comments} when is_list(comments) ->
        comments
        |> Enum.reverse()
        |> Enum.find_value(&requested_split_pr_number_from_comment/1)

      {:ok, _payload} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  defp requested_split_pr_number_from_comment(%{"body" => body}) when is_binary(body) do
    case Regex.run(~r/PR\s*(\d+)\s*구현/iu, body) do
      [_match, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp requested_split_pr_number_from_comment(_comment), do: nil

  defp first_unmerged_split_child_specs(all_specs) do
    Enum.reduce_while(all_specs, {:ok, []}, fn spec, _acc ->
      case split_child_merged?(spec) do
        {:ok, true} -> {:cont, {:ok, []}}
        {:ok, false} -> {:halt, {:ok, [spec]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp split_child_merged?(%{branch: branch}) when is_binary(branch) do
    case fetch_pull_request_status_for_branch(branch) do
      {:ok, %{merged?: true}} -> {:ok, true}
      {:ok, _status} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp integration_pull_request_spec(number, feature_branch, sections, parent_number) do
    %{
      number: number,
      branch: feature_branch,
      split?: true,
      integration?: true,
      sections: sections,
      section: nil,
      followups: [],
      parent_number: parent_number,
      state: "Waiting"
    }
  end

  defp issue_pull_request_title(%Issue{title: title}, %{integration?: true, number: number}) do
    title =
      case title do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: "Issue #{number}", else: value

        _ ->
          "Issue #{number}"
      end

    truncate_text("Issue ##{number}: #{title} 통합", 250)
  end

  defp issue_pull_request_title(%Issue{}, %{split?: true, number: number, section: section}) do
    section_title = section_title(section)
    truncate_text("Issue ##{number} PR#{section.number}: #{section_title}", 250)
  end

  defp issue_pull_request_title(%Issue{title: title}, %{number: number}) do
    title =
      case title do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: "Issue #{number}", else: value

        _ ->
          "Issue #{number}"
      end

    truncate_text("Issue ##{number}: #{title}", 250)
  end

  defp issue_pull_request_body(%Issue{} = issue, %{integration?: true, number: number, sections: sections} = spec) do
    issue_url = issue.url || "##{number}"
    parent_ref_text = parent_issue_ref_text(spec[:parent_number])
    child_text = child_pr_text(sections)

    """
    ## 작업 소스

    - 원본 이슈: #{issue_url}
    - 완료 시 연결 이슈 정리: Closes ##{number}
    #{parent_ref_text}\
    - 이 PR은 분할 PR들이 병합되는 feature 브랜치를 `main`으로 병합하기 위한 통합 PR입니다.
    - 모든 하위 분할 PR이 feature 브랜치에 병합될 때까지 이 PR은 `sym:waiting` 상태로 유지합니다.
    - 하위 분할 PR이 남아 있으면 이 PR을 implementation/review/rework/merge lane으로 실행하지 않습니다.
    - 모든 하위 분할 PR이 feature 브랜치에 병합된 뒤 사람이 이 PR을 `sym:merging`으로 진행합니다.

    ## 하위 분할 PR

    #{child_text}
    """
  end

  defp issue_pull_request_body(%Issue{} = issue, %{split?: true, number: number, section: section, followups: followups} = spec) do
    issue_url = issue.url || "##{number}"
    followup_text = followup_pr_text(followups)
    parent_ref_text = parent_issue_ref_text(spec[:parent_number])
    feature_branch = Map.fetch!(spec, :feature_branch)

    """
    ## 작업 소스

    - 원본 이슈: #{issue_url}
    - 연결 이슈 정리: Refs ##{number}
    #{parent_ref_text}\
    - 분할 PR: PR#{section.number} / #{length(followups) + 1}
    - 병합 대상: `#{feature_branch}` feature 브랜치
    - 이 PR은 `sym:planned` 이슈의 PR-sized 섹션에서 자동 생성되었습니다.
    - 실제 구현은 이 PR lane의 `sym:planned` 실행에서 진행하고, 완료 후 feature 브랜치로 병합합니다.

    ## 이번 PR 범위

    ### PR#{section.number}: #{section_title(section)}

    #{section.body}

    #{followup_text}
    """
  end

  defp issue_pull_request_body(%Issue{} = issue, %{number: number} = spec) do
    issue_url = issue.url || "##{number}"
    description = issue.description || ""
    parent_ref_text = parent_issue_ref_text(spec[:parent_number])

    """
    ## 작업 소스

    - 원본 이슈: #{issue_url}
    - 완료 시 연결 이슈 정리: Closes ##{number}
    #{parent_ref_text}\
    - 이 PR은 `sym:planned` 이슈에서 자동 생성되었습니다.
    - 실제 구현은 PR lane의 `sym:planned` 실행에서 진행합니다.

    ## 원본 이슈 내용

    #{description}
    """
  end

  defp parent_issue_ref_text(parent_number) when is_integer(parent_number) do
    "- 부모 이슈 정리: Refs ##{parent_number}\n"
  end

  defp parent_issue_ref_text(_parent_number), do: ""

  defp section_title(%{number: number, title: title}) when is_binary(title) do
    title = String.trim(title)
    if title == "", do: "PR#{number}", else: title
  end

  defp followup_pr_text([]), do: "## 후속 PR\n\n없음"

  defp followup_pr_text(followups) do
    items =
      followups
      |> Enum.map_join("\n", fn section -> "- PR#{section.number}: #{section_title(section)}" end)

    """
    ## 후속 PR

    #{items}
    """
    |> String.trim()
  end

  defp child_pr_text(sections) when is_list(sections) do
    sections
    |> Enum.map_join("\n", fn section -> "- PR#{section.number}: #{section_title(section)}" end)
  end

  defp maybe_mark_integration_pull_request(%Issue{} = pull_request, %{integration?: true}) do
    %{pull_request | metadata: Map.put(pull_request.metadata, :integration_pull_request?, true)}
  end

  defp maybe_mark_integration_pull_request(%Issue{} = pull_request, _spec), do: pull_request

  defp truncate_text(value, max_length) when is_binary(value) and is_integer(max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max(max_length - 3, 0)) <> "..."
    else
      value
    end
  end

  defp request(method, path, opts \\ []) when method in [:get, :post, :put, :patch, :delete] and is_binary(path) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, headers} <- github_headers(tracker) do
      request_opts =
        [
          method: method,
          url: github_url(tracker.endpoint, tracker.owner, tracker.repo, path),
          headers: headers,
          connect_options: [timeout: 30_000]
        ]
        |> maybe_put_json(Keyword.get(opts, :json))
        |> maybe_put_params(Keyword.get(opts, :params))

      request_fun = Application.get_env(:symphony_elixir, :github_request_fun, &Req.request/1)

      case request_fun.(request_opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          Logger.error("GitHub request failed method=#{method} path=#{path} status=#{status} body=#{inspect(body, limit: 20)}")
          {:error, github_api_error(status, body)}

        {:error, reason} ->
          Logger.error("GitHub request failed method=#{method} path=#{path}: #{inspect(reason)}")
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp github_api_error(status, body) do
    if github_retryable_api_status?(status, body) do
      {:github_retryable_api_status, status, body}
    else
      {:github_api_status, status, body}
    end
  end

  defp github_retryable_api_status?(status, _body) when status in [408, 429] or status >= 500, do: true
  defp github_retryable_api_status?(403, body), do: github_rate_limit_body?(body)
  defp github_retryable_api_status?(_status, _body), do: false

  defp github_rate_limited_graphql_errors?(errors) when is_list(errors) do
    Enum.any?(errors, &github_rate_limit_body?/1)
  end

  defp github_rate_limited_graphql_errors?(_errors), do: false

  defp github_rate_limit_body?(%{} = body) do
    [Map.get(body, "message", Map.get(body, :message, "")), Map.get(body, "type", Map.get(body, :type, ""))]
    |> Enum.any?(fn value ->
      normalized = value |> to_string() |> String.downcase()
      String.contains?(normalized, "rate limit") or String.contains?(normalized, "rate_limited")
    end)
  end

  defp github_rate_limit_body?(_body), do: false

  defp github_tracker_config do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_tracker_api_token}
      is_nil(tracker.owner) -> {:error, :missing_github_owner}
      is_nil(tracker.repo) -> {:error, :missing_github_repo}
      true -> {:ok, tracker}
    end
  end

  defp github_headers(tracker) do
    {:ok,
     [
       {"Accept", "application/vnd.github+json"},
       {"Authorization", "Bearer #{tracker.api_key}"},
       {"X-GitHub-Api-Version", "2022-11-28"},
       {"User-Agent", "symphony-elixir"}
     ]}
  end

  defp github_url(endpoint, _owner, _repo, "/search/" <> _ = path) do
    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp github_url(endpoint, owner, repo, path) do
    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>("/repos/#{owner}/#{repo}")
    |> Kernel.<>(path)
  end

  defp fetch_review_threads(tracker, number), do: fetch_review_threads(tracker, number, nil, [])

  defp fetch_review_threads(tracker, number, cursor, acc) do
    variables = %{owner: tracker.owner, repo: tracker.repo, number: number, cursor: cursor}

    with {:ok, response} <- graphql_request(tracker, @review_threads_query, variables),
         {:ok, pull_request} <- graphql_pull_request(response),
         {:ok, threads, page_info} <- graphql_review_threads(pull_request) do
      next_acc = acc ++ threads

      case page_info do
        %{"hasNextPage" => true, "endCursor" => next_cursor} when is_binary(next_cursor) and next_cursor != "" ->
          fetch_review_threads(tracker, number, next_cursor, next_acc)

        _ ->
          {:ok, %{head_oid: pull_request["headRefOid"], threads: next_acc}}
      end
    end
  end

  defp graphql_pull_request(%{"data" => %{"repository" => %{"pullRequest" => pull_request}}}) when is_map(pull_request),
    do: {:ok, pull_request}

  defp graphql_pull_request(_response), do: {:error, :github_review_thread_snapshot_invalid}

  defp graphql_review_threads(%{"reviewThreads" => %{"nodes" => threads, "pageInfo" => page_info}})
       when is_list(threads) and is_map(page_info),
       do: {:ok, threads, page_info}

  defp graphql_review_threads(_pull_request), do: {:error, :github_review_thread_snapshot_invalid}

  defp pull_request_head(%{"head" => %{"sha" => head}}) when is_binary(head) and head != "", do: {:ok, head}
  defp pull_request_head(_pull_request), do: {:error, :github_pull_request_head_missing}

  defp comment_evidence(comment) when is_map(comment) do
    %{body: Map.get(comment, "body", ""), author: get_in(comment, ["user", "login"])}
  end

  defp review_evidence(review) when is_map(review) do
    %{body: Map.get(review, "body", ""), state: Map.get(review, "state"), author: get_in(review, ["user", "login"])}
  end

  defp inline_comment_evidence(comment) when is_map(comment) do
    %{
      body: Map.get(comment, "body", ""),
      path: Map.get(comment, "path"),
      line: Map.get(comment, "line") || Map.get(comment, "original_line"),
      author: get_in(comment, ["user", "login"])
    }
  end

  defp review_thread_feedback(%{"id" => thread_ref} = thread) when is_binary(thread_ref) do
    bodies =
      thread
      |> get_in(["comments", "nodes"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "body", ""))
      |> Enum.reject(&(&1 == ""))

    %{thread_ref: thread_ref, feedback: Enum.join(bodies, "\n\n")}
  end

  defp validate_review_thread_snapshot(%{head_oid: expected_head_oid, threads: threads}, expected_head_oid, updates) do
    update_refs = MapSet.new(Enum.map(updates, &review_thread_ref/1))
    thread_refs = MapSet.new(Enum.map(threads, &Map.get(&1, "id")))

    unresolved_refs =
      threads
      |> Enum.reject(&(&1["isResolved"] == true))
      |> Enum.map(&Map.get(&1, "id"))
      |> MapSet.new()

    cond do
      MapSet.size(update_refs) != length(updates) -> {:conflict, :duplicate_review_thread_update}
      not MapSet.subset?(update_refs, thread_refs) -> {:conflict, :unknown_review_thread}
      not MapSet.subset?(unresolved_refs, update_refs) -> {:conflict, %{unaccounted_review_threads: MapSet.to_list(MapSet.difference(unresolved_refs, update_refs))}}
      true -> :ok
    end
  end

  defp validate_review_thread_snapshot(%{head_oid: actual_head_oid}, expected_head_oid, _updates),
    do: {:conflict, %{expected_head_oid: expected_head_oid, actual_head_oid: actual_head_oid}}

  defp apply_review_thread_updates(threads, updates, marker, tracker, number, expected_head_oid) do
    thread_by_ref = Map.new(threads, &{&1["id"], &1})

    Enum.reduce_while(updates, {:ok, [], [], []}, fn update, {:ok, completed, handoffs, replies} ->
      thread_ref = review_thread_ref(update)
      thread = Map.fetch!(thread_by_ref, thread_ref)

      case apply_review_thread_update(thread, update, marker, tracker, number) do
        :ok ->
          {:cont, {:ok, [thread_ref | completed], handoffs, replies}}

        {:handoff, reason} ->
          {:cont, {:ok, [thread_ref | completed], [{thread_ref, reason} | handoffs], replies}}

        {:retry, reason, reply} ->
          {:halt, {:retry, reason, Enum.reverse(completed), Enum.reverse(handoffs), [reply | replies]}}

        {:retry, reason} ->
          {:halt, {:retry, reason, Enum.reverse(completed), Enum.reverse(handoffs), replies}}
      end
    end)
    |> finalize_review_thread_updates(tracker, number, expected_head_oid)
  end

  defp finalize_review_thread_updates({:ok, completed, [], _replies}, tracker, number, expected_head_oid) do
    with {:ok, snapshot} <- fetch_review_threads(tracker, number),
         true <- snapshot.head_oid == expected_head_oid,
         [] <- Enum.reject(snapshot.threads, &(&1["isResolved"] == true)) do
      {:applied, %{resolved: completed}}
    else
      false ->
        {:conflict, %{expected_head_oid: expected_head_oid, reason: :review_thread_head_drift}}

      unresolved when is_list(unresolved) ->
        {:conflict, %{reason: :review_threads_remain_unresolved, thread_refs: Enum.map(unresolved, & &1["id"])}}

      {:error, reason} ->
        {:retry, reason, %{resolved: completed}}
    end
  end

  defp finalize_review_thread_updates(
         {:ok, completed, handoffs, _replies},
         _tracker,
         _number,
         _expected_head_oid
       ),
       do: review_thread_handoff_result(completed, handoffs)

  defp finalize_review_thread_updates(
         {:retry, reason, completed, handoffs, replies},
         _tracker,
         _number,
         _expected_head_oid
       ),
       do: {:retry, reason, %{completed: completed, needs_human: handoffs, replies: replies}}

  defp apply_review_thread_update(%{"isResolved" => true}, _update, _marker, _tracker, _number), do: :ok

  defp apply_review_thread_update(thread, update, marker, tracker, _number) do
    thread_ref = Map.fetch!(thread, "id")
    disposition = review_thread_disposition(update)
    thread_marker = "<!-- sym-review-thread:#{marker}:#{thread_ref} -->"

    case ensure_review_thread_reply(thread, update, thread_marker, tracker) do
      {:ok, reply_status} ->
        apply_review_thread_after_reply(
          disposition,
          thread_ref,
          thread_marker,
          tracker,
          reply_status
        )

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp review_thread_handoff_result(completed, handoffs) do
    {:handoff, :review_thread_needs_human, %{replied: Enum.reverse(completed), needs_human: Enum.reverse(handoffs)}}
  end

  defp apply_review_thread_after_reply("fixed", thread_ref, thread_marker, tracker, reply_status) do
    case resolve_review_thread(thread_ref, thread_marker, tracker) do
      :ok -> :ok
      {:retry, reason} -> {:retry, reason, %{thread_ref: thread_ref, reply: reply_status}}
    end
  end

  defp apply_review_thread_after_reply("needs_human", _thread_ref, _thread_marker, _tracker, _reply_status),
    do: {:handoff, :review_thread_needs_human}

  defp ensure_review_thread_reply(thread, update, thread_marker, tracker) do
    if review_thread_reply_present?(thread, thread_marker) do
      {:ok, :already_present}
    else
      input = %{
        pullRequestReviewThreadId: Map.fetch!(thread, "id"),
        body: review_thread_reply(update) <> "\n\n" <> thread_marker,
        clientMutationId: thread_marker
      }

      case graphql_request(tracker, @reply_to_review_thread_mutation, %{input: input}) do
        {:ok,
         %{
           "data" => %{
             "addPullRequestReviewThreadReply" => %{"comment" => %{"id" => _id}}
           }
         }} ->
          {:ok, :posted}

        {:ok, _response} ->
          {:error, :github_review_thread_reply_invalid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_review_thread(thread_ref, thread_marker, tracker) do
    input = %{threadId: thread_ref, clientMutationId: thread_marker}

    case graphql_request(tracker, @resolve_review_thread_mutation, %{input: input}) do
      {:ok,
       %{
         "data" => %{
           "resolveReviewThread" => %{"thread" => %{"isResolved" => true}}
         }
       }} ->
        :ok

      {:ok, _response} ->
        {:retry, :github_review_thread_resolve_invalid}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp review_thread_reply_present?(thread, marker) do
    thread
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.any?(fn comment -> is_binary(comment["body"]) and String.contains?(comment["body"], marker) end)
  end

  defp review_thread_ref(update), do: Map.get(update, :thread_ref) || Map.get(update, "thread_ref")
  defp review_thread_disposition(update), do: Map.get(update, :disposition) || Map.get(update, "disposition")
  defp review_thread_reply(update), do: Map.get(update, :reply_ko) || Map.get(update, "reply_ko")

  defp invalid_review_thread_closeout(issue_id, expected_head_oid) do
    {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, reason: :invalid_review_thread_closeout}}
  end

  defp graphql_request(tracker, query, variables) do
    request_fun = Application.get_env(:symphony_elixir, :github_request_fun, &Req.request/1)

    request_opts = [
      method: :post,
      url: github_graphql_url(tracker.endpoint),
      headers: github_headers(tracker) |> elem(1),
      json: %{query: query, variables: variables},
      connect_options: [timeout: 30_000]
    ]

    case request_fun.(request_opts) do
      {:ok, %{status: status, body: %{"errors" => errors} = body}} when status in 200..299 ->
        if github_rate_limited_graphql_errors?(errors),
          do: {:error, {:github_retryable_api_status, status, body}},
          else: {:error, {:github_graphql_errors, errors}}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, github_api_error(status, body)}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp github_graphql_url(endpoint) do
    endpoint
    |> String.trim_trailing("/")
    |> String.replace_suffix("/api/v3", "/api/graphql")
    |> append_graphql_path()
  end

  defp append_graphql_path(url) do
    if String.ends_with?(url, "/graphql"), do: url, else: url <> "/graphql"
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp maybe_put_params(opts, nil), do: opts
  defp maybe_put_params(opts, params), do: Keyword.put(opts, :params, params)

  defp parse_issue_id(id) do
    case HostedGit.decode_id("github", id) do
      {:ok, number, kind} -> {:ok, number, kind}
      :error -> {:error, {:invalid_github_issue_id, id}}
    end
  end

  defp label_for_state(state_name) when is_binary(state_name) do
    state_label_map()
    |> Enum.find_value(fn {state, label} ->
      if normalize_state(state) == normalize_state(state_name), do: label
    end)
  end

  defp label_for_state(_state_name), do: nil

  defp state_for_label(label) when is_binary(label) do
    label_to_state_map()
    |> Map.get(normalize_label(label))
  end

  defp state_for_label(_label), do: nil

  defp state_label_map do
    configured =
      Config.settings!().tracker.state_labels
      |> normalize_string_map()

    HostedGit.state_labels(configured)
  end

  defp label_to_state_map do
    state_label_map()
    |> Map.new(fn {state, label} -> {normalize_label(label), state} end)
  end

  defp normalize_string_map(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {to_string(key), to_string(raw_value)} end)
  end

  defp normalize_string_map(_value), do: %{}

  defp unique_issues(issues) do
    issues
    |> Enum.reduce(%{}, fn %Issue{id: id} = issue, acc -> Map.put_new(acc, id, issue) end)
    |> Map.values()
    |> Enum.sort_by(&(&1.identifier || &1.id || ""))
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_raw_issue), do: []

  defp issue_kind(%{"pull_request" => pull}) when is_map(pull), do: :pull_request
  defp issue_kind(_raw_issue), do: :issue

  defp github_issue_id(:pull_request, number), do: HostedGit.encode_id("github", :pull_request, number)
  defp github_issue_id(_kind, number), do: HostedGit.encode_id("github", :issue, number)

  defp github_identifier(:pull_request, number), do: "PR ##{number}"
  defp github_identifier(_kind, number), do: "##{number}"

  defp assignee_id(%{"login" => login}), do: login
  defp assignee_id(_assignee), do: nil

  defp pull_branch_name(%{"head" => %{"ref" => ref}}) when is_binary(ref), do: ref
  defp pull_branch_name(_pull_data), do: nil

  defp pull_merged?(%{"merged" => true}), do: true
  defp pull_merged?(_pull_data), do: false

  defp github_repository do
    tracker = Config.settings!().tracker
    "#{tracker.owner}/#{tracker.repo}"
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp normalize_state(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_state(value), do: value |> to_string() |> normalize_state()

  defp normalize_label(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_label(value), do: value |> to_string() |> normalize_label()

  defp label_present?(labels, target_label) when is_list(labels) and is_binary(target_label) do
    target_label = normalize_label(target_label)
    Enum.any?(labels, &(normalize_label(&1) == target_label))
  end

  defp label_present?(_labels, _target_label), do: false

  defp search_query_for_label(label) do
    tracker = Config.settings!().tracker
    ~s(repo:#{tracker.owner}/#{tracker.repo} label:"#{escape_search_qualifier(label)}")
  end

  defp escape_search_qualifier(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
