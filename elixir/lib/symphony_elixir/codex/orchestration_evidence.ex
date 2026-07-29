defmodule SymphonyElixir.Codex.OrchestrationEvidence do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @schema_version 1
  @max_bytes 8 * 1024 * 1024
  @filename "orchestration-evidence.yaml"
  @marker_regex ~r/<!--\s*sym-transition:([^>]+?)\s*-->/
  @region_names [
    "work_item",
    "unresolved_threads",
    "human_comments",
    "review_summaries",
    "inline_comments",
    "worker_reports",
    "transition_history",
    "deduplication_report"
  ]

  @type descriptor :: %{
          filename: String.t(),
          format: String.t(),
          schema_version: pos_integer(),
          bytes: non_neg_integer(),
          sha256: String.t(),
          required_regions: [String.t()],
          regions: %{String.t() => map()}
        }

  @spec build(map(), Issue.t()) :: {:ok, String.t(), descriptor()} | {:error, term()}
  def build(snapshot, %Issue{} = issue) when is_map(snapshot) do
    with {:ok, regions} <- build_regions(snapshot, issue),
         {:ok, rendered, region_index} <- render_indexed_yaml(regions),
         :ok <- validate_max_bytes(rendered),
         :ok <- validate_rendered_yaml(rendered, region_index) do
      descriptor = %{
        filename: @filename,
        format: "yaml",
        schema_version: @schema_version,
        bytes: byte_size(rendered),
        sha256: sha256(rendered),
        required_regions: required_regions(issue.state),
        regions: region_index
      }

      {:ok, rendered, descriptor}
    end
  end

  def build(_snapshot, _issue), do: {:error, :invalid_dispatch_snapshot}

  @doc false
  @spec max_bytes_for_test() :: pos_integer()
  def max_bytes_for_test, do: @max_bytes

  @doc false
  @spec validate_size_for_test(String.t()) :: :ok | {:error, term()}
  def validate_size_for_test(rendered), do: validate_max_bytes(rendered)

  @doc false
  @spec validate_rendered_for_test(String.t(), map()) :: :ok | {:error, term()}
  def validate_rendered_for_test(rendered, region_index),
    do: validate_rendered_yaml(rendered, region_index)

  defp build_regions(snapshot, issue) do
    work_item = snapshot_value(snapshot, :work_item, work_item_context(issue))
    unresolved_threads = snapshot_value(snapshot, :unresolved_feedback, [])
    top_level_comments = snapshot_value(snapshot, :top_level_comments, [])

    {human_comments, worker_reports, transition_history} =
      Enum.reduce(top_level_comments, {[], [], []}, fn comment, {human, worker, transition} ->
        case classify_top_level_comment(comment) do
          :human -> {[comment | human], worker, transition}
          :worker -> {human, [comment | worker], transition}
          :transition -> {human, worker, [comment | transition]}
        end
      end)
      |> then(fn {human, worker, transition} ->
        {Enum.reverse(human), Enum.reverse(worker), Enum.reverse(transition)}
      end)

    {human_comments, human_duplicates} = deduplicate(human_comments, "human_comments", false)

    {review_summaries, review_duplicates} =
      snapshot |> snapshot_value(:reviews, []) |> deduplicate("review_summaries", false)

    {inline_comments, inline_duplicates} =
      snapshot |> snapshot_value(:inline_comments, []) |> deduplicate("inline_comments", false)

    {worker_reports, worker_duplicates} = deduplicate(worker_reports, "worker_reports", true)

    {transition_history, transition_duplicates} =
      deduplicate(transition_history, "transition_history", true)

    duplicate_report =
      human_duplicates ++
        review_duplicates ++ inline_duplicates ++ worker_duplicates ++ transition_duplicates

    regions = [
      {"work_item", ordered_work_item(work_item, issue), 1},
      {"unresolved_threads", ordered_unresolved_threads(unresolved_threads), length(unresolved_threads)},
      {"human_comments", ordered_evidence(human_comments), length(human_comments)},
      {"review_summaries", ordered_evidence(review_summaries), length(review_summaries)},
      {"inline_comments", ordered_evidence(inline_comments), length(inline_comments)},
      {"worker_reports", ordered_evidence(worker_reports), length(worker_reports)},
      {"transition_history", ordered_evidence(transition_history), length(transition_history)},
      {"deduplication_report", ordered_duplicate_report(duplicate_report), length(duplicate_report)}
    ]

    {:ok, regions}
  rescue
    error -> {:error, {:orchestration_evidence_generation_failed, error}}
  end

  defp classify_top_level_comment(comment) do
    markers = transition_markers(evidence_value(comment, :body, ""))

    cond do
      Enum.any?(markers, &String.starts_with?(&1.id, "worker:")) -> :worker
      markers != [] -> :transition
      true -> :human
    end
  end

  defp deduplicate(items, region, strip_markers?) do
    {order, entries} =
      Enum.reduce(items, {[], %{}}, fn item, {order, entries} ->
        body = evidence_value(item, :body, "")
        markers = transition_markers(body)
        canonical_body = if strip_markers?, do: strip_transition_markers(body), else: body
        key = duplicate_key(item, canonical_body)
        occurrence = ordered_occurrence(item, markers)

        case Map.fetch(entries, key) do
          :error ->
            entry = %{
              item: item,
              body: canonical_body,
              occurrences: [occurrence],
              original_count: 1
            }

            {[key | order], Map.put(entries, key, entry)}

          {:ok, entry} ->
            updated = %{
              entry
              | occurrences: [occurrence | entry.occurrences],
                original_count: entry.original_count + 1
            }

            {order, Map.put(entries, key, updated)}
        end
      end)

    canonical =
      order
      |> Enum.reverse()
      |> Enum.map(fn key ->
        entry = Map.fetch!(entries, key)
        %{entry | occurrences: Enum.reverse(entry.occurrences)}
      end)

    duplicate_report =
      canonical
      |> Enum.filter(&(&1.original_count > 1))
      |> Enum.map(fn entry ->
        %{
          region: region,
          canonical_key: sha256(duplicate_key(entry.item, entry.body)),
          original_count: entry.original_count,
          retained_count: 1
        }
      end)

    {canonical, duplicate_report}
  end

  defp duplicate_key(item, body) do
    [
      evidence_value(item, :author, nil),
      evidence_value(item, :state, nil),
      evidence_value(item, :path, nil),
      evidence_value(item, :line, nil),
      body
    ]
    |> :erlang.term_to_binary()
  end

  defp ordered_work_item(work_item, issue) do
    ordered_map([
      {"identifier", evidence_value(work_item, :identifier, issue.identifier)},
      {"title", evidence_value(work_item, :title, issue.title)},
      {"description", literal(evidence_value(work_item, :description, issue.description) || "")},
      {"url", evidence_value(work_item, :url, issue.url)},
      {"kind", evidence_value(work_item, :kind, issue.kind)}
    ])
  end

  defp ordered_unresolved_threads(threads) do
    Enum.map(threads, fn thread ->
      comments =
        case evidence_value(thread, :comments, nil) do
          comments when is_list(comments) ->
            Enum.map(comments, &ordered_thread_comment/1)

          _ ->
            [
              ordered_map([
                {"body", literal(evidence_value(thread, :feedback, ""))}
              ])
            ]
        end

      ordered_map([
        {"thread_ref", evidence_value(thread, :thread_ref, nil)},
        {"path", evidence_value(thread, :path, nil)},
        {"line", evidence_value(thread, :line, nil)},
        {"comments", comments}
      ])
    end)
  end

  defp ordered_thread_comment(comment) do
    ordered_map([
      {"id", evidence_value(comment, :id, nil)},
      {"author", evidence_value(comment, :author, nil)},
      {"created_at", evidence_value(comment, :created_at, nil)},
      {"updated_at", evidence_value(comment, :updated_at, nil)},
      {"url", evidence_value(comment, :url, nil)},
      {"body", literal(evidence_value(comment, :body, ""))}
    ])
  end

  defp ordered_evidence(entries) do
    Enum.map(entries, fn entry ->
      item = entry.item

      ordered_map([
        {"author", evidence_value(item, :author, nil)},
        {"state", evidence_value(item, :state, nil)},
        {"path", evidence_value(item, :path, nil)},
        {"line", evidence_value(item, :line, nil)},
        {"body", literal(entry.body)},
        {"occurrences", entry.occurrences}
      ])
    end)
  end

  defp ordered_occurrence(item, markers) do
    ordered_map([
      {"id", evidence_value(item, :id, nil)},
      {"url", evidence_value(item, :url, nil)},
      {"created_at", evidence_value(item, :created_at, nil)},
      {"updated_at", evidence_value(item, :updated_at, nil)},
      {"submitted_at", evidence_value(item, :submitted_at, nil)},
      {"commit_id", evidence_value(item, :commit_id, nil)},
      {"markers", Enum.map(markers, &ordered_map([{"raw", &1.raw}, {"id", &1.id}]))}
    ])
  end

  defp ordered_duplicate_report(entries) do
    Enum.map(entries, fn entry ->
      ordered_map([
        {"region", entry.region},
        {"canonical_key", entry.canonical_key},
        {"original_count", entry.original_count},
        {"retained_count", entry.retained_count}
      ])
    end)
  end

  defp render_indexed_yaml(regions) do
    rendered_regions =
      Enum.map(regions, fn {name, value, count} ->
        rendered = render_region(name, value)
        {name, rendered, count}
      end)

    placeholder_index =
      Map.new(rendered_regions, fn {name, rendered, count} ->
        {name, index_entry(0, 0, count, rendered)}
      end)

    placeholder_header = render_header(placeholder_index)
    first_region_line = line_count(placeholder_header) + 1

    {_next_line, region_index} =
      Enum.reduce(rendered_regions, {first_region_line, %{}}, fn {name, rendered, count}, {start_line, index} ->
        end_line = start_line + line_count(rendered) - 1
        entry = index_entry(start_line, end_line, count, rendered)
        {end_line + 1, Map.put(index, name, entry)}
      end)

    header = render_header(region_index)
    rendered = header <> Enum.map_join(rendered_regions, "", fn {_name, section, _count} -> section end)

    if line_count(header) == line_count(placeholder_header) do
      {:ok, rendered, region_index}
    else
      {:error, :orchestration_evidence_index_unstable}
    end
  end

  defp render_header(region_index) do
    index_pairs =
      Enum.map(@region_names, fn name ->
        entry = Map.fetch!(region_index, name)

        {name,
         ordered_map([
           {"start_line", padded_line(entry.start_line)},
           {"end_line", padded_line(entry.end_line)},
           {"count", entry.count},
           {"bytes", entry.bytes},
           {"sha256", entry.sha256}
         ])}
      end)

    render_pairs([
      {"schema_version", @schema_version},
      {"index", ordered_map(index_pairs)}
    ])
  end

  defp render_region(name, value), do: render_pairs([{name, value}])

  defp render_pairs(pairs), do: render_value(ordered_map(pairs), 0)

  defp render_value({:ordered_map, pairs}, indent) do
    Enum.map_join(pairs, "", &render_pair(&1, indent))
  end

  defp render_value(values, indent) when is_list(values) do
    if values == [] do
      "#{spaces(indent)}[]\n"
    else
      Enum.map_join(values, "", &render_list_item(&1, indent))
    end
  end

  defp render_pair({key, {:literal, literal_value}}, indent) do
    normalized = normalize_line_endings(literal_value)
    chomping = if String.ends_with?(normalized, "\n"), do: "|+2", else: "|-2"

    "#{spaces(indent)}#{key}: #{chomping}\n" <>
      render_literal_body(normalized, indent + 2)
  end

  defp render_pair({key, value}, indent) do
    if complex_value?(value) do
      "#{spaces(indent)}#{key}:\n" <> render_value(value, indent + 2)
    else
      "#{spaces(indent)}#{key}: #{render_scalar(value)}\n"
    end
  end

  defp render_literal_body(value, indent) do
    if value == "" do
      ""
    else
      value
      |> String.split("\n", trim: false)
      |> maybe_drop_terminal_line(value)
      |> Enum.map_join("\n", &(spaces(indent) <> &1))
      |> Kernel.<>("\n")
    end
  end

  defp maybe_drop_terminal_line(lines, value) do
    if String.ends_with?(value, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  defp render_list_item(value, indent) do
    "#{spaces(indent)}-\n" <> render_value(value, indent + 2)
  end

  defp render_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp render_scalar(true), do: "true"
  defp render_scalar(false), do: "false"
  defp render_scalar(value), do: Jason.encode!(to_string(value))

  defp complex_value?({:ordered_map, _pairs}), do: true
  defp complex_value?(value) when is_list(value), do: true
  defp complex_value?(_value), do: false

  defp ordered_map(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> then(&{:ordered_map, &1})
  end

  defp literal(value), do: {:literal, to_string(value || "")}

  defp index_entry(start_line, end_line, count, rendered) do
    %{
      start_line: start_line,
      end_line: end_line,
      count: count,
      bytes: byte_size(rendered),
      sha256: sha256(rendered)
    }
  end

  defp validate_max_bytes(rendered) do
    if byte_size(rendered) <= @max_bytes do
      :ok
    else
      {:error, {:orchestration_evidence_too_large, byte_size(rendered)}}
    end
  end

  defp validate_rendered_yaml(rendered, region_index) do
    case YamlElixir.read_from_string(rendered) do
      {:ok, decoded} ->
        with true <- decoded["schema_version"] == @schema_version,
             true <- is_map(decoded["index"]),
             :ok <- validate_decoded_index(decoded["index"], region_index),
             :ok <- validate_region_slices(rendered, region_index) do
          :ok
        else
          false -> {:error, :invalid_orchestration_evidence_yaml}
          {:index_error, reason} -> {:error, reason}
          {:slice_error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:invalid_orchestration_evidence_yaml, reason}}
    end
  end

  defp validate_decoded_index(decoded_index, region_index) do
    decoded_regions = decoded_index |> Map.keys() |> MapSet.new()

    if MapSet.equal?(decoded_regions, MapSet.new(@region_names)) do
      Enum.reduce_while(@region_names, :ok, fn name, :ok ->
        entry = Map.fetch!(region_index, name)
        validate_decoded_index_entry(name, Map.get(decoded_index, name), entry)
      end)
    else
      {:index_error, {:orchestration_evidence_index_mismatch, "index"}}
    end
  end

  defp validate_decoded_index_entry(name, decoded_entry, entry) do
    expected = %{
      "start_line" => padded_line(entry.start_line),
      "end_line" => padded_line(entry.end_line),
      "count" => entry.count,
      "bytes" => entry.bytes,
      "sha256" => entry.sha256
    }

    if decoded_entry == expected,
      do: {:cont, :ok},
      else: {:halt, {:index_error, {:orchestration_evidence_index_mismatch, name}}}
  end

  defp validate_region_slices(rendered, region_index) do
    lines = String.split(rendered, "\n", trim: false)

    Enum.reduce_while(@region_names, :ok, fn name, :ok ->
      entry = Map.fetch!(region_index, name)

      slice =
        lines
        |> Enum.slice(entry.start_line - 1, entry.end_line - entry.start_line + 1)
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      if byte_size(slice) == entry.bytes and sha256(slice) == entry.sha256 do
        {:cont, :ok}
      else
        {:halt, {:slice_error, {:orchestration_evidence_index_mismatch, name}}}
      end
    end)
  end

  defp transition_markers(body) do
    @marker_regex
    |> Regex.scan(body)
    |> Enum.map(fn [raw, id] -> %{raw: raw, id: String.trim(id)} end)
  end

  defp strip_transition_markers(body) do
    @marker_regex
    |> Regex.replace(body, "")
  end

  defp required_regions(state) do
    base = ["work_item", "unresolved_threads"]

    case state |> to_string() |> String.downcase() |> String.trim() do
      state when state in ["review", "reviewing", "rework", "reworking"] ->
        base ++ ["human_comments", "review_summaries", "inline_comments"]

      "merging" ->
        base ++ ["human_comments", "review_summaries", "inline_comments", "worker_reports"]

      _ ->
        base ++ ["human_comments"]
    end
  end

  defp work_item_context(issue) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      url: issue.url,
      kind: issue.kind
    }
  end

  defp snapshot_value(snapshot, key, default) do
    Map.get(snapshot, key) || Map.get(snapshot, Atom.to_string(key)) || default
  end

  defp evidence_value(evidence, key, default) when is_map(evidence) do
    case Map.fetch(evidence, key) do
      {:ok, value} -> value
      :error -> Map.get(evidence, Atom.to_string(key), default)
    end
  end

  defp evidence_value(_evidence, _key, default), do: default

  defp normalize_line_endings(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp padded_line(value), do: value |> Integer.to_string() |> String.pad_leading(8, "0")

  defp line_count(value), do: value |> :binary.matches("\n") |> length()

  defp spaces(count), do: String.duplicate(" ", count)

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
