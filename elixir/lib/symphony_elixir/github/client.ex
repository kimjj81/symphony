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

  defp fetch_issues_by_labels([]), do: {:ok, []}

  defp fetch_issues_by_labels(labels) do
    labels
    |> collect_issues_for_labels()
    |> normalize_issues_for_labels()
  end

  defp collect_issues_for_labels(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
      label
      |> list_issues_for_label()
      |> append_label_issues(acc)
    end)
  end

  defp append_label_issues({:ok, issues}, acc), do: {:cont, {:ok, issues ++ acc}}
  defp append_label_issues({:error, reason}, _acc), do: {:halt, {:error, reason}}

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
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp list_issues_for_label(label), do: list_issues_for_label(label, 1, [])

  defp list_issues_for_label(label, page, acc) do
    case request(:get, "/issues", params: %{state: "all", labels: label, per_page: @per_page, page: page}) do
      {:ok, issues} when is_list(issues) ->
        next_acc = acc ++ issues

        if length(issues) == @per_page do
          list_issues_for_label(label, page + 1, next_acc)
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

      case Req.request(request_opts) do
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
end
