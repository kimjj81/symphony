defmodule SymphonyElixir.HostedGit do
  @moduledoc """
  Provider-neutral workflow rules shared by hosted Git trackers.

  Provider clients own authentication, REST paths, and payload normalization;
  this module owns Symphony label policy and pull-request plan parsing.
  """

  @default_state_labels %{
    "Todo" => "sym:todo",
    "Planned" => "sym:planned",
    "In Progress" => "sym:in-progress",
    "Review" => "sym:review",
    "Reviewing" => "sym:reviewing",
    "Human Review" => "sym:human-review",
    "Waiting" => "sym:waiting",
    "Rework" => "sym:rework",
    "Reworking" => "sym:reworking",
    "Merging" => "sym:merging",
    "Done" => "sym:done",
    "Canceled" => "sym:canceled",
    "Duplicate" => "sym:duplicate"
  }
  @request_labels %{
    "sym:request-planned" => "Planned",
    "sym:request-rework" => "Rework",
    "sym:request-merging" => "Merging",
    "sym:request-human-review" => "Human Review",
    "sym:request-canceled" => "Canceled",
    "sym:request-duplicate" => "Duplicate",
    "sym:request-reopen" => "Human Review"
  }

  @spec default_state_labels() :: %{String.t() => String.t()}
  def default_state_labels, do: @default_state_labels

  @spec request_labels() :: %{String.t() => String.t()}
  def request_labels, do: @request_labels

  @spec request_labels(map() | nil) :: %{String.t() => String.t()}
  def request_labels(configured) do
    configured
    |> normalize_string_map()
    |> Map.new(fn {state, label} -> {label, state} end)
    |> then(&Map.merge(@request_labels, &1))
  end

  @spec state_labels(map() | nil) :: %{String.t() => String.t()}
  def state_labels(configured) do
    configured =
      if is_map(configured),
        do: Map.new(configured, fn {key, value} -> {to_string(key), to_string(value)} end),
        else: %{}

    Map.merge(@default_state_labels, configured)
  end

  @spec classify_managed_label(term(), map() | nil) ::
          {:request, String.t()} | {:state, String.t()} | :unmanaged
  def classify_managed_label(label, configured),
    do: classify_managed_label(label, configured, nil)

  @spec classify_managed_label(term(), map() | nil, map() | nil) ::
          {:request, String.t()} | {:state, String.t()} | :unmanaged
  def classify_managed_label(label, configured, human_intent_labels) when is_binary(label) do
    normalized = normalize(label)

    case Enum.find(request_labels(human_intent_labels), fn {name, _state} -> normalize(name) == normalized end) do
      {_name, state} ->
        {:request, state}

      nil ->
        case state_for_label(label, configured) do
          nil -> :unmanaged
          state -> {:state, state}
        end
    end
  end

  def classify_managed_label(_label, _configured, _human_intent_labels), do: :unmanaged

  @spec state_for_label(String.t(), map() | nil) :: String.t() | nil
  def state_for_label(label, configured) when is_binary(label) do
    state_labels(configured)
    |> Enum.find_value(fn {state, name} -> if normalize(name) == normalize(label), do: state end)
  end

  @spec label_for_state(String.t(), map() | nil) :: String.t() | nil
  def label_for_state(state, configured) when is_binary(state) do
    state_labels(configured)
    |> Enum.find_value(fn {name, label} -> if normalize(name) == normalize(state), do: label end)
  end

  @spec pull_request_sections(String.t()) :: [map()]
  def pull_request_sections(description) when is_binary(description) do
    matches = Regex.scan(~r/^###\s*PR\s*(\d+)\s*[:：.\-–—]?\s*(.*?)\s*$/im, description, return: :index)

    matches
    |> Enum.with_index()
    |> Enum.map(fn {[{start, length}, {number_start, number_length}, {title_start, title_length}], index} ->
      body_start = start + length

      body_end =
        case Enum.at(matches, index + 1) do
          [{next_start, _} | _] -> next_start
          _ -> byte_size(description)
        end

      %{
        number: description |> binary_part(number_start, number_length) |> String.to_integer(),
        title: description |> binary_part(title_start, title_length) |> String.trim(),
        body: description |> binary_part(body_start, body_end - body_start) |> String.trim()
      }
    end)
    |> Enum.filter(&(&1.title != "" or &1.body != ""))
  end

  @doc """
  Rejects ambiguous split-PR plans before a provider derives branch names and
  `[current/total]` titles from them. Numbering must be a unique 1..N sequence.
  """
  @spec validate_pull_request_sections([map()]) :: :ok | {:error, term()}
  def validate_pull_request_sections(sections) when is_list(sections) do
    numbers = Enum.map(sections, &Map.get(&1, :number))

    case numbers do
      [] ->
        :ok

      _ ->
        if numbers == Enum.to_list(1..length(numbers)//1),
          do: :ok,
          else: {:error, {:invalid_pull_request_section_sequence, numbers}}
    end
  end

  @spec parallel_pull_request_plan?(String.t()) :: boolean()
  def parallel_pull_request_plan?(description) when is_binary(description) do
    Regex.match?(~r/(PR\s*진행\s*방식|실행\s*방식|execution\s*mode)\s*[:：-]?\s*(병렬|parallel)/iu, description)
  end

  @spec encode_id(String.t(), :issue | :pull_request, pos_integer()) :: String.t()
  def encode_id(provider, :issue, number), do: "#{provider}:issue:#{number}"
  def encode_id(provider, :pull_request, number), do: "#{provider}:pr:#{number}"

  @spec decode_id(String.t(), String.t()) :: {:ok, pos_integer(), :issue | :pull_request | nil} | :error
  def decode_id(provider, id) when is_binary(provider) and is_binary(id) do
    issue_prefix = provider <> ":issue:"
    pull_prefix = provider <> ":pr:"

    cond do
      String.starts_with?(id, issue_prefix) -> parse_number(String.replace_prefix(id, issue_prefix, ""), :issue)
      String.starts_with?(id, pull_prefix) -> parse_number(String.replace_prefix(id, pull_prefix, ""), :pull_request)
      String.starts_with?(id, "#") -> parse_number(String.replace_prefix(id, "#", ""), :issue)
      String.starts_with?(id, "PR #") -> parse_number(String.replace_prefix(id, "PR #", ""), :pull_request)
      true -> parse_number(id, nil)
    end
  end

  defp parse_number(number, kind) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed, kind}
      _ -> :error
    end
  end

  defp normalize_string_map(configured) when is_map(configured) do
    Map.new(configured, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_string_map(_configured), do: %{}

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
