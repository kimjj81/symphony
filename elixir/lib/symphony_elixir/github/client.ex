defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST client for polling Issues and Pull Requests as tracker work items.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker.Issue}

  @per_page 100
  @default_state_labels %{
    "Todo" => "sym:todo",
    "Planned" => "sym:planned",
    "In Progress" => "sym:in-progress",
    "Review" => "sym:review",
    "Reviewing" => "sym:reviewing",
    "Human Review" => "sym:human-review",
    "Rework" => "sym:rework",
    "Merging" => "sym:merging",
    "Done" => "sym:done",
    "Canceled" => "sym:canceled",
    "Duplicate" => "sym:duplicate"
  }
  @label_meta %{
    "sym:todo" => {"ededed", "Symphony should triage or prepare this item."},
    "sym:planned" => {"bfd4ff", "Human-approved work ready for Symphony implementation."},
    "sym:in-progress" => {"f9d66d", "Symphony or a human is actively working on this item."},
    "sym:review" => {"0969da", "Ready for Symphony automated review."},
    "sym:reviewing" => {"1f883d", "Symphony automated review is running."},
    "sym:human-review" => {"2da44e", "Waiting for human review or approval."},
    "sym:rework" => {"fb8f44", "Review requested changes for Symphony to address."},
    "sym:merging" => {"d4c5f9", "Approved work is being merged or finalized."},
    "sym:done" => {"8250df", "Completed successfully."},
    "sym:canceled" => {"8c959f", "Closed without completion."},
    "sym:duplicate" => {"8c959f", "Duplicate work item."}
  }

  @spec default_state_labels() :: map()
  def default_state_labels, do: @default_state_labels

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
        :skip -> {:cont, {:ok, acc}}
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         {:ok, _body} <- request(:post, "/issues/#{number}/comments", json: %{body: body}) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, number, _kind} <- parse_issue_id(issue_id),
         target_label when is_binary(target_label) <- label_for_state(state_name),
         {:ok, raw_issue} <- request(:get, "/issues/#{number}"),
         current_labels <- extract_labels(raw_issue),
         :ok <- ensure_label(target_label),
         :ok <- remove_state_labels(number, current_labels),
         {:ok, _body} <- request(:post, "/issues/#{number}/labels", json: %{labels: [target_label]}) do
      :ok
    else
      nil -> {:error, {:unknown_github_state, state_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_state_update_failed}
    end
  end

  @spec create_pull_request_for_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def create_pull_request_for_issue(%Issue{kind: :issue} = issue) do
    case parse_issue_id(issue.id) do
      {:ok, number, :issue} ->
        create_issue_pull_requests(issue, issue_pull_request_specs(number, issue))

      {:ok, _number, kind} ->
        {:error, {:unsupported_github_issue_kind, kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_pull_request_for_issue(%Issue{kind: kind}), do: {:error, {:unsupported_github_issue_kind, kind}}

  @doc false
  @spec normalize_issue_for_test(map()) :: {:ok, Issue.t()} | :skip
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
      {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
      :skip -> {:cont, {:ok, acc}}
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
         {:ok, raw_issue} <- request(:get, "/issues/#{number}") do
      normalize_issue(raw_issue, fetch_pull_data(number, expected_kind, raw_issue))
    end
  end

  defp fetch_pull_data(number, expected_kind, raw_issue) do
    if pull_data_required?(expected_kind, raw_issue), do: fetch_pull(number), else: nil
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

  defp normalize_issue(raw_issue, pull_data \\ nil) when is_map(raw_issue) do
    labels = extract_labels(raw_issue)

    case state_from_labels(labels) do
      {:ok, state} ->
        state = state || fallback_closed_state(raw_issue, pull_data)

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
               merged: pull_merged?(pull_data)
             },
             labels: labels,
             assigned_to_worker: true,
             created_at: parse_datetime(raw_issue["created_at"]),
             updated_at: parse_datetime(raw_issue["updated_at"])
           }}
        end

      {:error, {:ambiguous_state_labels, states}} ->
        Logger.warning("Skipping GitHub issue with ambiguous Symphony state labels number=#{inspect(raw_issue["number"])} states=#{inspect(states)}")
        :skip
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
    cond do
      issue_kind(raw_issue) == :pull_request and pull_merged?(pull_data) -> "Done"
      issue_kind(raw_issue) == :pull_request -> "Canceled"
      true -> "Done"
    end
  end

  defp fallback_closed_state(_raw_issue, _pull_data), do: nil

  defp remove_state_labels(number, current_labels) do
    state_label_set =
      state_label_map()
      |> Map.values()
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    current_labels
    |> Enum.filter(fn label -> MapSet.member?(state_label_set, normalize_label(label)) end)
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case request(:delete, "/issues/#{number}/labels/#{URI.encode_www_form(label)}") do
        {:ok, _body} -> {:cont, :ok}
        {:error, {:github_api_status, 404, _body}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_label(label) when is_binary(label) do
    case request(:get, "/labels/#{URI.encode_www_form(label)}") do
      {:ok, _body} ->
        :ok

      {:error, {:github_api_status, 404, _body}} ->
        {color, description} = Map.get(@label_meta, label, {"ededed", "Symphony workflow state."})

        case request(:post, "/labels", json: %{name: label, color: color, description: description}) do
          {:ok, _body} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_open_pull_request_for_branch(branch) when is_binary(branch) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, pulls} <-
           request(:get, "/pulls", params: %{state: "open", head: "#{tracker.owner}:#{branch}", per_page: 1}) do
      case pulls do
        [%{"number" => number} | _] when is_integer(number) ->
          fetch_visible_or_plan_pull_request("github:pr:#{number}")

        [] ->
          {:ok, nil}

        _ ->
          {:error, :github_unexpected_pulls_payload}
      end
    end
  end

  defp fetch_visible_or_plan_pull_request(issue_id) do
    case fetch_issue_by_id(issue_id) do
      {:ok, %Issue{} = issue} ->
        {:ok, issue}

      :skip ->
        with :ok <- update_issue_state(issue_id, "Planned") do
          fetch_visible_issue_by_id(issue_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
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
      {:ok, pull_requests} when pull_requests != [] -> {:ok, pull_requests |> Enum.reverse() |> List.first()}
      {:ok, []} -> {:error, :github_pull_request_creation_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_or_create_issue_pull_request(issue, %{branch: branch} = spec) do
    case fetch_open_pull_request_for_branch(branch) do
      {:ok, %Issue{} = pull_request} ->
        {:ok, pull_request}

      {:ok, nil} ->
        create_issue_pull_request(issue, spec)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_issue_pull_request(issue, %{number: number, branch: branch} = spec) do
    with {:ok, base_branch} <- pull_request_base_branch(),
         {:ok, _branch_sha} <- ensure_issue_pull_request_branch(issue, number, branch, base_branch),
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
         :ok <- update_issue_state(pull_request_id, "Planned") do
      fetch_visible_issue_by_id(pull_request_id)
    else
      {:error, {:github_api_status, 422, _body}} ->
        case fetch_open_pull_request_for_branch(branch) do
          {:ok, %Issue{} = pull_request} -> {:ok, pull_request}
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

  defp issue_pull_request_specs(number, %Issue{} = issue) when is_integer(number) do
    sections = issue_pr_sections(issue.description || "")

    if length(sections) >= 2 do
      all_specs =
        Enum.map(sections, fn section ->
          %{
            number: number,
            branch: "symphony/_#{number}-pr#{section.number}",
            split?: true,
            section: section,
            followups: Enum.reject(sections, &(&1.number == section.number))
          }
        end)

      if parallel_pr_plan?(issue.description || "") do
        all_specs
      else
        [List.first(all_specs)]
      end
    else
      [
        %{
          number: number,
          branch: issue_pull_request_branch(number),
          split?: false,
          section: nil,
          followups: []
        }
      ]
    end
  end

  defp issue_pull_request_branch(number) when is_integer(number), do: "symphony/_#{number}"

  defp issue_pr_sections(description) when is_binary(description) do
    regex = ~r/^###\s*PR\s*(\d+)\s*[:：.\-–—]?\s*(.*?)\s*$/im
    matches = Regex.scan(regex, description, return: :index)

    matches
    |> Enum.with_index()
    |> Enum.map(fn {[{start, length}, {number_start, number_length}, {title_start, title_length}], index} ->
      body_start = start + length
      body_end = next_match_start(matches, index, byte_size(description))

      %{
        number: description |> binary_part(number_start, number_length) |> String.to_integer(),
        title: description |> binary_part(title_start, title_length) |> String.trim(),
        body: description |> binary_part(body_start, body_end - body_start) |> String.trim()
      }
    end)
    |> Enum.filter(&(&1.title != "" or &1.body != ""))
  end

  defp next_match_start(matches, index, fallback) do
    case Enum.at(matches, index + 1) do
      [{start, _length} | _captures] -> start
      _ -> fallback
    end
  end

  defp parallel_pr_plan?(description) when is_binary(description) do
    Regex.match?(~r/(PR\s*진행\s*방식|실행\s*방식|execution\s*mode)\s*[:：-]?\s*(병렬|parallel)/iu, description)
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

  defp issue_pull_request_body(%Issue{} = issue, %{split?: true, number: number, section: section, followups: followups}) do
    issue_url = issue.url || "##{number}"
    followup_text = followup_pr_text(followups)

    """
    ## 작업 소스

    - 원본 이슈: #{issue_url}
    - 연결 이슈 정리: Refs ##{number}
    - 분할 PR: PR#{section.number} / #{length(followups) + 1}
    - 이 PR은 `sym:planned` 이슈의 PR-sized 섹션에서 자동 생성되었습니다.
    - 실제 구현은 이 PR lane의 `sym:planned` 실행에서 진행합니다.

    ## 이번 PR 범위

    ### PR#{section.number}: #{section_title(section)}

    #{section.body}

    #{followup_text}
    """
  end

  defp issue_pull_request_body(%Issue{} = issue, %{number: number}) do
    issue_url = issue.url || "##{number}"
    description = issue.description || ""

    """
    ## 작업 소스

    - 원본 이슈: #{issue_url}
    - 완료 시 연결 이슈 정리: Closes ##{number}
    - 이 PR은 `sym:planned` 이슈에서 자동 생성되었습니다.
    - 실제 구현은 PR lane의 `sym:planned` 실행에서 진행합니다.

    ## 원본 이슈 내용

    #{description}
    """
  end

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

  defp truncate_text(value, max_length) when is_binary(value) and is_integer(max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max(max_length - 3, 0)) <> "..."
    else
      value
    end
  end

  defp request(method, path, opts \\ []) when method in [:get, :post, :delete] and is_binary(path) do
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
          {:error, {:github_api_status, status, body}}

        {:error, reason} ->
          Logger.error("GitHub request failed method=#{method} path=#{path}: #{inspect(reason)}")
          {:error, {:github_api_request, reason}}
      end
    end
  end

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

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  defp maybe_put_params(opts, nil), do: opts
  defp maybe_put_params(opts, params), do: Keyword.put(opts, :params, params)

  defp parse_issue_id("github:issue:" <> number), do: parse_number(number, :issue)
  defp parse_issue_id("github:pr:" <> number), do: parse_number(number, :pull_request)
  defp parse_issue_id("#" <> number), do: parse_number(number, :issue)
  defp parse_issue_id("PR #" <> number), do: parse_number(number, :pull_request)
  defp parse_issue_id(number), do: parse_number(number, nil)

  defp parse_number(number, kind) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed, kind}
      _ -> {:error, {:invalid_github_issue_id, number}}
    end
  end

  defp label_for_state(state_name) when is_binary(state_name) do
    state_label_map()
    |> Enum.find_value(fn {state, label} ->
      if normalize_state(state) == normalize_state(state_name), do: label
    end)
  end

  defp label_for_state(_state_name), do: nil

  defp state_label_map do
    configured =
      Config.settings!().tracker.state_labels
      |> normalize_string_map()

    Map.merge(@default_state_labels, configured)
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

  defp github_issue_id(:pull_request, number), do: "github:pr:#{number}"
  defp github_issue_id(_kind, number), do: "github:issue:#{number}"

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
