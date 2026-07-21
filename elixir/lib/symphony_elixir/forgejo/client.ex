defmodule SymphonyElixir.Forgejo.Client do
  @moduledoc """
  Forgejo v16 REST client for tracker issues and same-repository pull requests.

  Forgejo labels are written by numeric ID. This client always reads the live
  label set before replacing managed state labels so repository-owned labels
  are not lost.
  """

  require Logger

  alias SymphonyElixir.{Config, HostedGit, Tracker.Issue}

  @supported_major 16
  @per_page 50
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

  @spec default_state_labels() :: map()
  def default_state_labels, do: HostedGit.default_state_labels()

  @spec request_labels() :: map()
  def request_labels, do: HostedGit.request_labels()

  @spec classify_managed_label(term()) ::
          {:request, String.t()} | {:state, String.t()} | :unmanaged
  def classify_managed_label(label) when is_binary(label) do
    HostedGit.classify_managed_label(
      label,
      Config.settings!().tracker.state_labels,
      Config.settings!().state_manager.human_intent_labels
    )
  end

  def classify_managed_label(_label), do: :unmanaged

  @doc "Checks that the configured server speaks the supported Forgejo major version."
  @spec preflight() :: :ok | {:error, term()}
  def preflight do
    with {:ok, %{"version" => version}} when is_binary(version) <-
           request(:get, :root, "/version"),
         {:ok, actual} <- version_major(version) do
      if actual == @supported_major,
        do: :ok,
        else: {:error, {:unsupported_forgejo_major, actual, @supported_major}}
    else
      {:ok, payload} -> {:error, {:forgejo_version_missing, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_issues_by_states(Config.settings!().tracker.active_states)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    desired = states |> Enum.map(&normalize/1) |> MapSet.new()

    with {:ok, issues} <- list_all(:issue),
         {:ok, pulls} <- list_all(:pull_request) do
      items = Enum.map(issues, &{:issue, &1}) ++ Enum.map(pulls, &{:pull_request, &1})
      normalize_tracker_items(items, desired)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case fetch_issue(id) do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(body) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         {:ok, _} <- request(:post, :repo, "/issues/#{number}/comments", json: %{body: body}) do
      :ok
    end
  end

  @spec create_comment_once(String.t(), String.t(), String.t()) ::
          :applied | :already_applied | {:error, term()}
  def create_comment_once(issue_id, body, marker)
      when is_binary(body) and is_binary(marker) and marker != "" do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         {:ok, comments} <- list_pages("/issues/#{number}/comments") do
      create_comment_once_from_snapshot(number, comments, body, marker)
    end
  end

  def create_comment_once(_issue_id, _body, _marker), do: {:error, :invalid_comment_marker}

  defp create_comment_once_from_snapshot(number, comments, body, marker) do
    if Enum.any?(comments, &comment_has_marker?(&1, marker)) do
      :already_applied
    else
      marked = if String.contains?(body, marker), do: body, else: body <> "\n\n" <> marker

      case request(:post, :repo, "/issues/#{number}/comments", json: %{body: marked}) do
        {:ok, _} -> :applied
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state) do
    case apply_state_projection(issue_id, :any, state) do
      {status, _snapshot} when status in [:applied, :already_applied] -> :ok
      {:conflict, snapshot} -> {:error, {:forgejo_state_conflict, snapshot}}
      {:partial_failure, snapshot} -> {:error, {:forgejo_state_projection_failed, snapshot}}
    end
  end

  @spec apply_state_projection(String.t(), String.t() | nil | :any, String.t()) ::
          {:applied, map()}
          | {:already_applied, map()}
          | {:conflict, map()}
          | {:partial_failure, map()}
  def apply_state_projection(issue_id, expected, target)
      when is_binary(issue_id) and is_binary(target) do
    with {:ok, number, kind} <- parse_issue_id(issue_id),
         {:ok, raw} <- request(:get, :repo, "/issues/#{number}"),
         {:ok, _parent_number} <- parse_parent_number(label_names(raw)),
         {:ok, current_state} <- state_from_labels(label_names(raw)),
         true <-
           expected_matches?(expected, current_state) or expected_matches?(target, current_state),
         :ok <- guarded_projection_target(number, kind, target),
         effective_label when is_binary(effective_label) <- label_for_state(target),
         {:ok, target_label} <- ensure_label(effective_label) do
      current_labels = Map.get(raw, "labels", [])
      desired = projected_label_ids(current_labels, target_label)
      snapshot = %{issue_id: issue_id, state: current_state, labels: label_names(raw)}

      apply_projection_snapshot(
        number,
        kind,
        raw,
        target,
        desired,
        snapshot
      )
    else
      nil ->
        {:partial_failure, %{stage: :validate, reason: {:unknown_forgejo_state, target}}}

      false ->
        projection_conflict(issue_id, expected, target)

      {:error, {:forgejo_parent_completion_deferred, _number} = reason} ->
        {:conflict, %{issue_id: issue_id, reason: reason}}

      {:error, {:invalid_forgejo_parent_labels, _labels} = reason} ->
        {:conflict, %{issue_id: issue_id, reason: reason}}

      {:error, reason} ->
        {:partial_failure, %{stage: :read_or_prepare, reason: reason}}
    end
  end

  @spec create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def create_pull_request_for_issue(%Issue{kind: :issue} = issue) do
    with {:ok, number, :issue} <- parse_issue_id(issue.id),
         {:ok, selected, selected_number, parent_number} <- select_planned_issue(issue, number),
         {:ok, specs} <- pull_request_specs(selected, selected_number, parent_number),
         {:ok, pulls} <- create_pull_requests(selected, specs) do
      {:ok,
       Enum.find(pulls, List.first(pulls), fn pull ->
         not Map.get(pull.metadata, :integration_pull_request?, false)
       end)}
    end
  end

  def create_pull_request_for_issue(%Issue{kind: kind}),
    do: {:error, {:unsupported_forgejo_issue_kind, kind}}

  @spec merge_pull_request(String.t(), String.t()) ::
          {:applied, map()} | {:conflict, map()} | {:error, map()}
  def merge_pull_request(issue_id, expected_head_oid)
      when is_binary(expected_head_oid) and expected_head_oid != "" do
    with {:ok, number, :pull_request} <- parse_issue_id(issue_id),
         {:ok, pull} <- request(:get, :repo, "/pulls/#{number}"),
         :ok <- ensure_same_repository_pull(pull) do
      current = get_in(pull, ["head", "sha"])

      cond do
        current != expected_head_oid ->
          {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, current_head_oid: current}}

        pull_merged?(pull) ->
          merge_result(issue_id, current, pull, true)

        true ->
          perform_merge(issue_id, number, expected_head_oid)
      end
    else
      {:ok, _number, kind} ->
        {:error, %{stage: :validate, reason: {:unsupported_forgejo_issue_kind, kind}}}

      {:error, reason} ->
        {:error, %{stage: :read, reason: reason}}
    end
  end

  def merge_pull_request(issue_id, expected_head_oid),
    do: {:error, %{stage: :validate, reason: {:invalid_merge_request, issue_id, expected_head_oid}}}

  @doc false
  @spec normalize_issue_for_test(map(), :issue | :pull_request) ::
          {:ok, Issue.t()} | :skip | {:error, term()}
  def normalize_issue_for_test(raw, kind), do: normalize_issue(raw, kind)

  @doc false
  @spec select_planned_issue_for_test(Issue.t(), pos_integer(), [map()]) ::
          {:ok, Issue.t(), pos_integer(), pos_integer() | nil} | {:error, term()}
  def select_planned_issue_for_test(issue, number, issues),
    do: select_planned_issue_from_items(issue, number, issues)

  @doc false
  @spec pull_title_for_test(Issue.t(), map()) :: String.t()
  def pull_title_for_test(issue, spec), do: pull_title(issue, spec)

  defp perform_merge(issue_id, number, expected_head_oid, attempts_left \\ 20) do
    payload = %{Do: "squash", head_commit_id: expected_head_oid}

    case request(:post, :repo, "/pulls/#{number}/merge", json: payload) do
      {:ok, _body} ->
        verify_merge(issue_id, number, expected_head_oid)

      {:error, {:forgejo_api_status, status, body}} when status in [409, 422] ->
        {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, reason: body}}

      {:error, {:forgejo_api_status, 405, body}} when attempts_left > 0 ->
        if pending_merge_response?(body) do
          retry_pending_merge(issue_id, number, expected_head_oid, attempts_left, body)
        else
          {:error, %{stage: :merge, reason: {:forgejo_api_status, 405, body}}}
        end

      {:error, reason} ->
        {:error, %{stage: :merge, reason: reason}}
    end
  end

  defp retry_pending_merge(issue_id, number, expected_head_oid, attempts_left, body) do
    with {:ok, pull} <- request(:get, :repo, "/pulls/#{number}"),
         :ok <- ensure_same_repository_pull(pull) do
      current_head_oid = get_in(pull, ["head", "sha"])

      cond do
        current_head_oid != expected_head_oid ->
          {:conflict,
           %{
             issue_id: issue_id,
             expected_head_oid: expected_head_oid,
             current_head_oid: current_head_oid
           }}

        pull_merged?(pull) ->
          merge_result(issue_id, current_head_oid, pull, true)

        true ->
          Process.sleep(250)
          perform_merge(issue_id, number, expected_head_oid, attempts_left - 1)
      end
    else
      {:error, reason} -> {:error, %{stage: :merge_wait, reason: reason, response: body}}
    end
  end

  defp verify_merge(issue_id, number, expected_head_oid) do
    with {:ok, pull} <- request(:get, :repo, "/pulls/#{number}"),
         :ok <- ensure_same_repository_pull(pull),
         true <- pull_merged?(pull),
         ^expected_head_oid <- get_in(pull, ["head", "sha"]) do
      merge_result(issue_id, expected_head_oid, pull, false)
    else
      false ->
        {:error, %{stage: :verify, reason: :forgejo_merge_not_observed}}

      actual when is_binary(actual) ->
        {:conflict, %{issue_id: issue_id, expected_head_oid: expected_head_oid, current_head_oid: actual}}

      {:error, reason} ->
        {:error, %{stage: :verify, reason: reason}}

      other ->
        {:error, %{stage: :verify, reason: {:forgejo_unexpected_merge_verification, other}}}
    end
  end

  defp merge_result(issue_id, head_oid, pull, already?) do
    {:applied,
     %{
       issue_id: issue_id,
       merged: true,
       already_applied: already?,
       head_oid: head_oid,
       merge_commit_sha: pull["merge_commit_sha"] || pull["merge_base"]
     }}
  end

  defp apply_projection_snapshot(number, kind, raw, target, desired_ids, snapshot) do
    labels = Map.get(raw, "labels", [])

    with {:ok, status, verified_labels} <- ensure_projected_labels(number, labels, desired_ids),
         {:ok, ^target} <- state_from_labels(label_names(%{"labels" => verified_labels})),
         :ok <- ensure_projected_open_state(number, kind, target, raw) do
      result = if status == :already_applied, do: :already_applied, else: :applied
      {result, %{snapshot | state: target, labels: label_names(%{"labels" => verified_labels})}}
    else
      {:error, reason} ->
        {:partial_failure, %{stage: :write_or_verify, reason: reason, before: snapshot}}

      other ->
        {:partial_failure, %{stage: :verify, reason: other, before: snapshot}}
    end
  end

  defp ensure_projected_labels(number, labels, desired_ids) when is_list(labels) do
    if same_label_ids?(labels, desired_ids) do
      {:ok, :already_applied, labels}
    else
      with {:ok, _} <-
             request(:put, :repo, "/issues/#{number}/labels", json: %{labels: desired_ids}),
           {:ok, verified} <- request(:get, :repo, "/issues/#{number}/labels"),
           true <- same_label_ids?(verified, desired_ids) do
        {:ok, :applied, verified}
      else
        false -> {:error, :forgejo_projection_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_projected_open_state(number, :issue, target, raw) do
    state = if terminal_state?(target), do: "closed", else: "open"

    if raw["state"] == state,
      do: :ok,
      else: project_and_verify_open_state("/issues/#{number}", state)
  end

  defp ensure_projected_open_state(number, :pull_request, target, raw) do
    state = if terminal_state?(target), do: "closed", else: "open"

    if raw["state"] == state,
      do: :ok,
      else: project_and_verify_open_state("/pulls/#{number}", state)
  end

  defp project_and_verify_open_state(path, expected_state) do
    with {:ok, _} <- request(:patch, :repo, path, json: %{state: expected_state}),
         {:ok, %{"state" => ^expected_state}} <- request(:get, :repo, path) do
      :ok
    else
      {:ok, payload} -> {:error, {:forgejo_open_state_mismatch, expected_state, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The client never substitutes a policy target. The StateManager owns the
  # derived Human Review handoff and its journal entry.
  defp guarded_projection_target(number, :issue, target) do
    if terminal_state?(target) do
      case parent_terminal_guard(number) do
        :allow -> :ok
        :defer -> {:error, {:forgejo_parent_completion_deferred, number}}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp guarded_projection_target(_number, _kind, _target), do: :ok

  defp parent_terminal_guard(parent_number) do
    with {:ok, children} <- list_children(parent_number) do
      terminal_guard_for_children(children)
    end
  end

  defp terminal_guard_for_children(children) do
    with :ok <- validate_parent_labels(children) do
      if Enum.all?(children, &terminal_child?/1), do: :allow, else: :defer
    end
  end

  defp terminal_child?(raw) do
    case state_from_labels(label_names(raw)) do
      {:ok, state} when is_binary(state) -> terminal_state?(state)
      {:ok, nil} -> raw["state"] == "closed"
      {:error, _reason} -> false
    end
  end

  defp projection_conflict(issue_id, expected, target) do
    case fetch_issue(issue_id) do
      {:ok, issue} ->
        {:conflict,
         %{
           issue_id: issue_id,
           state: issue.state,
           labels: issue.labels,
           expected_state: expected,
           target_state: target
         }}

      _ ->
        {:conflict, %{issue_id: issue_id, expected_state: expected, target_state: target}}
    end
  end

  defp select_planned_issue(issue, number) do
    with {:ok, children} <- list_children(number) do
      select_planned_issue_from_items(issue, number, children)
    end
  end

  defp select_planned_issue_from_items(issue, number, issues) do
    with {:ok, issue_parent} <- parse_parent_number(issue.labels) do
      select_planned_child(issue, number, issue_parent, issues)
    end
  end

  defp select_planned_child(issue, number, issue_parent, issues) do
    candidates = Enum.filter(issues, &declares_parent?(&1, number))

    with :ok <- validate_parent_labels(candidates) do
      select_planned_child_candidate(issue, number, issue_parent, candidates)
    end
  end

  defp select_planned_child_candidate(issue, number, issue_parent, candidates) do
    child =
      candidates
      |> Enum.sort_by(&(&1["number"] || &1["index"] || 0))
      |> Enum.find(fn raw ->
        raw["state"] != "closed" and
          match?({:ok, "Planned"}, state_from_labels(label_names(raw)))
      end)

    cond do
      child -> normalize_selected_child(child, number)
      candidates == [] -> {:ok, issue, number, issue_parent}
      true -> {:error, {:forgejo_no_planned_child_issue, number}}
    end
  end

  defp normalize_selected_child(raw, parent_number) do
    case normalize_issue(raw, :issue) do
      {:ok, selected} -> {:ok, selected, raw["number"], parent_number}
      :skip -> {:error, {:forgejo_no_planned_child_issue, parent_number}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pull_request_specs(issue, number, parent_number) do
    sections = HostedGit.pull_request_sections(issue.description || "")

    with :ok <- HostedGit.validate_pull_request_sections(sections) do
      pull_request_specs_from_sections(issue, number, parent_number, sections)
    end
  end

  defp pull_request_specs_from_sections(_issue, number, parent_number, sections)
       when length(sections) < 2 do
    {:ok, [%{number: number, branch: "symphony/_#{number}", parent_number: parent_number}]}
  end

  defp pull_request_specs_from_sections(issue, number, parent_number, sections) do
    feature = "symphony/_#{number}-feature"

    integration = %{
      number: number,
      branch: feature,
      integration?: true,
      sections: sections,
      parent_number: parent_number
    }

    all_children =
      Enum.map(sections, fn section ->
        %{
          number: number,
          branch: "symphony/_#{number}-pr#{section.number}",
          base: feature,
          branch_base: feature,
          feature_branch: feature,
          section: section,
          sections: sections,
          parent_number: parent_number
        }
      end)

    case split_child_specs(issue.description || "", all_children) do
      {:ok, children} -> {:ok, [integration | children]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_child_specs(description, all_specs) do
    if HostedGit.parallel_pull_request_plan?(description) do
      {:ok, all_specs}
    else
      first_unmerged_split_child(all_specs)
    end
  end

  defp first_unmerged_split_child(all_specs) do
    Enum.reduce_while(all_specs, {:ok, []}, fn spec, _acc ->
      case split_child_merged?(spec.branch, Map.fetch!(spec, :base)) do
        {:ok, true} -> {:cont, {:ok, []}}
        {:ok, false} -> {:halt, {:ok, [spec]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp split_child_merged?(branch, base) do
    with {:ok, pulls} <- list_pages("/pulls", %{state: "all", head: branch}) do
      case matching_pulls(pulls, branch, base) do
        [] ->
          {:ok, false}

        [pull] ->
          {:ok, pull_merged?(pull)}

        pulls ->
          {:error, {:ambiguous_forgejo_pull_request, branch, base, Enum.map(pulls, & &1["number"])}}
      end
    end
  end

  defp create_pull_requests(issue, specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case fetch_or_create_pull(issue, spec) do
        {:ok, pull} -> {:cont, {:ok, [pull | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pulls} -> {:ok, Enum.reverse(pulls)}
      error -> error
    end
  end

  defp fetch_or_create_pull(issue, spec) do
    with {:ok, base} <- base_branch(),
         target <- Map.get(spec, :base, base),
         {:ok, existing} <- open_pull_for_branch(spec.branch, target) do
      if existing, do: converge_pull(existing, spec), else: create_pull(issue, spec)
    end
  end

  defp open_pull_for_branch(branch, base) do
    with {:ok, pulls} <- list_pages("/pulls", %{state: "open", head: branch}) do
      case matching_pulls(pulls, branch, base) do
        [] -> {:ok, nil}
        [pull] -> {:ok, pull}
        matches -> {:error, {:ambiguous_forgejo_pull_request, branch, base, Enum.map(matches, & &1["number"])}}
      end
    end
  end

  defp matching_pulls(pulls, branch, base) do
    Enum.filter(pulls, fn pull ->
      get_in(pull, ["head", "ref"]) == branch and
        get_in(pull, ["base", "ref"]) == base and
        ensure_same_repository_pull(pull) == :ok
    end)
  end

  defp create_pull(issue, spec) do
    with {:ok, base} <- base_branch(),
         target <- Map.get(spec, :base, base),
         branch_base <- Map.get(spec, :branch_base, base),
         :ok <- maybe_ensure_feature_branch(spec, base),
         :ok <- ensure_branch(spec.branch, branch_base),
         {:ok, raw} <- request(:post, :repo, "/pulls", json: pull_payload(issue, spec, target)) do
      converge_pull(raw, spec)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_ensure_feature_branch(%{feature_branch: branch}, base),
    do: ensure_branch(branch, base)

  defp maybe_ensure_feature_branch(_spec, _base), do: :ok

  defp ensure_branch(branch, old_branch) do
    case request(:get, :repo, "/branches/#{URI.encode_www_form(branch)}") do
      {:ok, _} ->
        :ok

      {:error, {:forgejo_api_status, 404, _}} ->
        case request(:post, :repo, "/branches", json: %{new_branch_name: branch, old_branch_name: old_branch}) do
          {:ok, _} -> :ok
          {:error, {:forgejo_api_status, status, _}} when status in [409, 422] -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pull_payload(issue, spec, base) do
    %{
      title: pull_title(issue, spec),
      head: spec.branch,
      base: base,
      body: pull_body(issue, spec),
      draft: false
    }
  end

  defp pull_title(issue, %{integration?: true, number: number, sections: sections}),
    do: "[#{length(sections) + 1}/#{length(sections) + 1}] Issue ##{number}: #{issue.title || "Issue #{number}"} integration"

  defp pull_title(_issue, %{number: number, section: section, sections: sections}),
    do: "[#{section.number}/#{length(sections) + 1}] Issue ##{number}: #{section.title}"

  defp pull_title(issue, %{number: number}),
    do: "Issue ##{number}: #{issue.title || "Issue #{number}"}"

  defp pull_body(issue, %{integration?: true, number: number, sections: sections} = spec) do
    refs = parent_ref(spec.parent_number)
    children = Enum.map_join(sections, "\n", &"- PR#{&1.number}: #{&1.title}")

    "Original issue: #{issue.url || "##{number}"}\nCloses ##{number}\n#{refs}Integration PR for split work.\n\n#{children}"
  end

  defp pull_body(issue, %{number: number, section: section, feature_branch: feature} = spec) do
    refs = parent_ref(spec.parent_number)

    "Original issue: #{issue.url || "##{number}"}\nRefs ##{number}\n#{refs}Target feature branch: `#{feature}`\n\n### PR#{section.number}: #{section.title}\n\n#{section.body}"
  end

  defp pull_body(issue, %{number: number} = spec) do
    "Original issue: #{issue.url || "##{number}"}\nCloses ##{number}\n#{parent_ref(spec.parent_number)}\n#{issue.description || ""}"
  end

  defp parent_ref(number) when is_integer(number), do: "Refs ##{number}\n"
  defp parent_ref(_number), do: ""

  defp mark_integration(pull, %{integration?: true}),
    do: %{pull | metadata: Map.put(pull.metadata, :integration_pull_request?, true)}

  defp mark_integration(pull, _spec), do: pull

  defp converge_pull(raw, spec) do
    with :ok <- ensure_same_repository_pull(raw),
         number when is_integer(number) <- raw["number"],
         {:ok, current_state} <- state_from_labels(label_names(raw)),
         state <- current_state || default_pull_state(spec),
         :ok <- add_parent_label(number, spec.parent_number),
         :ok <- update_issue_state("forgejo:pr:#{number}", state),
         {:ok, pull} <- fetch_issue("forgejo:pr:#{number}") do
      {:ok, mark_integration(pull, spec)}
    else
      nil -> {:error, :forgejo_pull_request_number_missing}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:forgejo_pull_request_convergence_failed, other}}
    end
  end

  defp default_pull_state(spec), do: if(Map.get(spec, :integration?, false), do: "Waiting", else: "Planned")

  defp base_branch do
    base = Config.settings!().workspace.base_ref |> to_string() |> String.trim()

    cond do
      base in ["", "HEAD"] ->
        case request(:get, :repo, "") do
          {:ok, %{"default_branch" => branch}} when is_binary(branch) -> {:ok, branch}
          {:ok, body} -> {:error, {:forgejo_default_branch_missing, body}}
          error -> error
        end

      String.starts_with?(base, "origin/") ->
        {:ok, String.replace_prefix(base, "origin/", "")}

      String.starts_with?(base, "refs/heads/") ->
        {:ok, String.replace_prefix(base, "refs/heads/", "")}

      true ->
        {:ok, base}
    end
  end

  defp list_all(:issue), do: list_pages("/issues", %{state: "all", type: "issues"})
  defp list_all(:pull_request), do: list_pages("/pulls", %{state: "all"})

  defp list_children(parent_number) when is_integer(parent_number) do
    list_pages("/issues", %{state: "all", type: "issues", labels: "sym:parent-#{parent_number}"})
  end

  defp list_pages(path, params \\ %{}, page \\ 1, acc \\ []) do
    case request(:get, :repo, path, params: Map.merge(params, %{page: page, limit: @per_page})) do
      {:ok, items} when is_list(items) and length(items) == @per_page ->
        list_pages(path, params, page + 1, acc ++ items)

      {:ok, items} when is_list(items) ->
        {:ok, acc ++ items}

      {:ok, payload} ->
        {:error, {:forgejo_unexpected_list_payload, path, payload}}

      error ->
        error
    end
  end

  defp fetch_issue(id) do
    with {:ok, number, kind} <- parse_issue_id(id),
         {:ok, raw} <-
           request(
             :get,
             :repo,
             if(kind == :pull_request, do: "/pulls/#{number}", else: "/issues/#{number}")
           ) do
      normalize_issue(raw, kind || :issue)
    end
  end

  defp normalize_issue(raw, kind) when kind in [:issue, :pull_request] do
    with :ok <- if(kind == :pull_request, do: ensure_same_repository_pull(raw), else: :ok),
         {:ok, parent} <- parse_parent_number(label_names(raw)),
         {:ok, state} <- state_from_labels(label_names(raw)) do
      state = physical_state(raw, kind, state)
      if is_nil(state), do: :skip, else: {:ok, issue_struct(raw, kind, state, parent)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_struct(raw, kind, state, parent) do
    number = raw["number"] || raw["index"]

    %Issue{
      id: forgejo_id(kind, number),
      identifier: if(kind == :pull_request, do: "Forgejo PR ##{number}", else: "Forgejo ##{number}"),
      title: raw["title"],
      description: raw["body"],
      state: state,
      branch_name: get_in(raw, ["head", "ref"]),
      url: raw["html_url"],
      assignee_id: get_in(raw, ["assignee", "login"]),
      kind: kind,
      labels: label_names(raw),
      assigned_to_worker: true,
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"]),
      metadata: %{
        tracker: "forgejo",
        number: number,
        repository: repository(),
        physical_state: raw["state"],
        merged: pull_merged?(raw),
        head_oid: get_in(raw, ["head", "sha"]),
        parent_number: parent
      }
    }
  end

  defp normalize_tracker_items(items, desired) do
    items
    |> Enum.reduce_while({:ok, []}, fn {kind, raw}, {:ok, acc} ->
      normalize_tracker_item(raw, kind, desired, acc)
    end)
    |> case do
      {:ok, issues} -> {:ok, issues |> Enum.reverse() |> unique_issues()}
      error -> error
    end
  end

  defp normalize_tracker_item(raw, kind, desired, acc) do
    case normalize_issue(raw, kind) do
      {:ok, %Issue{state: state} = issue} ->
        next = if MapSet.member?(desired, normalize(state)), do: [issue | acc], else: acc
        {:cont, {:ok, next}}

      :skip ->
        {:cont, {:ok, acc}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # A merged pull request is physically terminal, but an older canonical
  # `sym:merging` label must still pass through the StateManager once so it can
  # journal and project `sym:done`. After that projection, normalizing the
  # same pull returns Done.
  defp physical_state(%{"merged" => true}, :pull_request, "Merging"), do: "Merging"
  defp physical_state(%{"merged" => true}, :pull_request, _state), do: "Done"
  defp physical_state(%{"state" => "closed"}, :pull_request, state), do: closed_state(state)
  defp physical_state(%{"state" => "closed"}, :issue, state), do: closed_state(state)
  defp physical_state(_raw, :pull_request, state), do: state
  defp physical_state(_raw, _kind, state), do: state

  defp closed_state(state) when is_binary(state) do
    if terminal_state?(state), do: state, else: "Canceled"
  end

  defp closed_state(_state), do: "Canceled"

  defp ensure_same_repository_pull(raw) do
    expected = normalize(repository())
    expected_origin = forgejo_origin(Config.settings!().tracker.endpoint)
    head_repo = get_in(raw, ["head", "repo"])
    base_repo = get_in(raw, ["base", "repo"])

    if same_repository_identity?(head_repo, expected, expected_origin) and
         same_repository_identity?(base_repo, expected, expected_origin) and
         get_in(head_repo || %{}, ["id"]) == get_in(base_repo || %{}, ["id"]) do
      :ok
    else
      {:error, :cross_repository_pull_request}
    end
  end

  defp same_repository_identity?(repo, expected_name, expected_origin) when is_map(repo) do
    normalize(repo["full_name"]) == expected_name and
      forgejo_origin(repo["html_url"] || repo["url"]) == expected_origin and
      is_integer(repo["id"])
  end

  defp same_repository_identity?(_repo, _expected_name, _expected_origin), do: false

  defp forgejo_origin(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      scheme = String.downcase(uri.scheme)
      {scheme, String.downcase(uri.host), uri.port || URI.default_port(scheme)}
    end
  end

  defp forgejo_origin(_), do: nil

  defp pending_merge_response?(%{"message" => message}) when is_binary(message) do
    String.contains?(String.downcase(message), "try again later")
  end

  defp pending_merge_response?(_body), do: false

  defp ensure_label(name) do
    with {:ok, labels} <- list_pages("/labels") do
      case Enum.find(labels, &(normalize(&1["name"]) == normalize(name))) do
        %{"id" => id} = label when is_integer(id) -> {:ok, label}
        nil -> create_label(name)
        label -> {:error, {:forgejo_label_id_missing, label}}
      end
    end
  end

  defp create_label(name) do
    {color, description} = Map.get(@label_meta, name, {"ededed", "Symphony workflow state."})

    case request(:post, :repo, "/labels", json: %{name: name, color: color, description: description}) do
      {:ok, %{"id" => id} = label} when is_integer(id) -> {:ok, label}
      {:ok, body} -> {:error, {:forgejo_label_id_missing, body}}
      error -> error
    end
  end

  defp add_parent_label(_number, nil), do: :ok

  defp add_parent_label(number, parent) when is_integer(parent) do
    with {:ok, %{"id" => id}} <- ensure_label("sym:parent-#{parent}"),
         {:ok, _} <- request(:post, :repo, "/issues/#{number}/labels", json: %{labels: [id]}) do
      :ok
    end
  end

  defp projected_label_ids(current, %{"id" => target_id}) do
    current
    |> Enum.reject(fn label -> classify_managed_label(label["name"]) != :unmanaged end)
    |> Enum.map(& &1["id"])
    |> Enum.filter(&is_integer/1)
    |> Kernel.++([target_id])
    |> Enum.uniq()
  end

  defp same_label_ids?(labels, desired) when is_list(labels) do
    ids =
      Enum.map(labels, fn
        %{"id" => id} -> id
        id when is_integer(id) -> id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    MapSet.new(ids) == MapSet.new(desired)
  end

  defp state_from_labels(labels) do
    states = labels |> Enum.map(&state_for_label/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case states do
      [] -> {:ok, nil}
      [state] -> {:ok, state}
      many -> {:error, {:ambiguous_state_labels, many}}
    end
  end

  defp state_for_label(label) when is_binary(label) do
    state_labels()
    |> Enum.find_value(fn {state, name} -> if normalize(name) == normalize(label), do: state end)
  end

  defp state_for_label(_), do: nil

  defp label_for_state(state) do
    state_labels()
    |> Enum.find_value(fn {key, label} -> if normalize(key) == normalize(state), do: label end)
  end

  defp state_labels, do: HostedGit.state_labels(Config.settings!().tracker.state_labels)

  defp label_names(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize/1)
  end

  defp label_names(_), do: []

  defp parse_parent_number(labels) when is_list(labels) do
    candidates = Enum.filter(labels, &(normalize(&1) |> String.starts_with?("sym:parent-")))

    case candidates do
      [] ->
        {:ok, nil}

      [label] ->
        case Regex.run(~r/^sym:parent-([1-9]\d*)$/i, to_string(label)) do
          [_, number] -> {:ok, String.to_integer(number)}
          _ -> {:error, {:invalid_forgejo_parent_labels, candidates}}
        end

      _ ->
        {:error, {:invalid_forgejo_parent_labels, candidates}}
    end
  end

  defp parse_parent_number(_labels), do: {:error, {:invalid_forgejo_parent_labels, []}}

  defp declares_parent?(raw, number) do
    expected = "sym:parent-#{number}"
    Enum.any?(label_names(raw), &(normalize(&1) == expected))
  end

  defp validate_parent_labels(issues) do
    Enum.reduce_while(issues, :ok, fn raw, :ok ->
      case parse_parent_number(label_names(raw)) do
        {:ok, _parent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp expected_matches?(:any, _), do: true
  defp expected_matches?(nil, nil), do: true

  defp expected_matches?(left, right) when is_binary(left) and is_binary(right),
    do: normalize(left) == normalize(right)

  defp expected_matches?(_, _), do: false

  defp terminal_state?(state), do: normalize(state) in ["done", "canceled", "duplicate"]
  defp pull_merged?(raw), do: raw["merged"] == true

  defp comment_has_marker?(%{"body" => body}, marker) when is_binary(body),
    do: String.contains?(body, marker)

  defp comment_has_marker?(_, _), do: false

  defp request(method, scope, path, opts \\ []) do
    with {:ok, tracker} <- tracker_config() do
      base = String.trim_trailing(tracker.endpoint, "/")

      url =
        if scope == :root,
          do: base <> path,
          else: base <> "/repos/#{tracker.owner}/#{tracker.repo}" <> path

      request_opts = [
        method: method,
        url: url,
        headers: [
          {"Accept", "application/json"},
          {"Authorization", "token #{tracker.api_key}"},
          {"User-Agent", "symphony-elixir"}
        ],
        connect_options: [timeout: 30_000]
      ]

      request_opts =
        if json = Keyword.get(opts, :json),
          do: Keyword.put(request_opts, :json, json),
          else: request_opts

      request_opts =
        if params = Keyword.get(opts, :params),
          do: Keyword.put(request_opts, :params, params),
          else: request_opts

      fun = Application.get_env(:symphony_elixir, :forgejo_request_fun, &Req.request/1)

      case fun.(request_opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:forgejo_api_status, status, body}}
        {:error, reason} -> {:error, {:forgejo_api_request, reason}}
      end
    end
  end

  defp tracker_config do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.endpoint) -> {:error, :missing_forgejo_endpoint}
      not is_binary(tracker.api_key) -> {:error, :missing_tracker_api_token}
      not is_binary(tracker.owner) -> {:error, :missing_forgejo_owner}
      not is_binary(tracker.repo) -> {:error, :missing_forgejo_repo}
      true -> {:ok, tracker}
    end
  end

  defp parse_issue_id(id) do
    case HostedGit.decode_id("forgejo", id) do
      {:ok, number, kind} -> {:ok, number, kind}
      :error -> {:error, {:invalid_forgejo_issue_id, id}}
    end
  end

  defp version_major(version) do
    case Regex.run(~r/^(\d+)/, version) do
      [_, major] -> {:ok, String.to_integer(major)}
      _ -> {:error, {:invalid_forgejo_version, version}}
    end
  end

  defp forgejo_id(:pull_request, number),
    do: HostedGit.encode_id("forgejo", :pull_request, number)

  defp forgejo_id(_, number), do: HostedGit.encode_id("forgejo", :issue, number)

  defp repository do
    tracker = Config.settings!().tracker
    "#{tracker.owner}/#{tracker.repo}"
  end

  defp unique_issues(issues) do
    issues |> Map.new(&{&1.id, &1}) |> Map.values() |> Enum.sort_by(&(&1.identifier || &1.id))
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
