defmodule SymphonyElixir.Codex.OrchestrationBrief do
  @moduledoc false

  alias SymphonyElixir.Codex.OrchestrationEvidence
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  @max_bytes 8_192

  @spec generate(Path.t(), Issue.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def generate(workspace, %Issue{} = issue, opts) do
    case Keyword.get(opts, :brief_generator) do
      generator when is_function(generator, 2) ->
        normalize_generated(generator.(workspace, issue), issue)

      _ ->
        snapshot_fetcher = Keyword.get(opts, :snapshot_fetcher, &Tracker.fetch_dispatch_snapshot/1)

        with {:ok, snapshot} <- snapshot_fetcher.(issue) do
          render_snapshot(snapshot, issue)
        end
    end
  end

  @spec fallback(Issue.t()) :: String.t()
  def fallback(%Issue{} = _issue) do
    """
    live_head: unknown
    unresolved_feedback: []
    feedback: broker snapshot unavailable; do not query GitHub
    focused_verification: run git diff --check and only tests or static checks directly covering changed files
    stop_conditions: broker snapshot is required before worker dispatch
    """
    |> String.trim()
  end

  @doc false
  @spec decode_for_test(String.t() | nil, Issue.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def decode_for_test(nil, _issue), do: {:error, :missing_orchestration_brief}

  def decode_for_test(text, issue) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, brief} when is_map(brief) -> normalize_generated({:ok, brief}, issue)
      {:error, reason} -> {:error, {:invalid_orchestration_brief_json, reason}}
      _ -> {:error, :invalid_orchestration_brief}
    end
  end

  @doc false
  @spec normalize_for_test(term(), Issue.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def normalize_for_test(result, issue), do: normalize_generated(result, issue)

  defp render_snapshot(snapshot, issue) when is_map(snapshot) do
    with {:ok, evidence, descriptor} <- OrchestrationEvidence.build(snapshot, issue) do
      rendered = snapshot |> snapshot_brief(issue, descriptor) |> render()

      normalize_snapshot_rendered(rendered, issue, evidence, descriptor)
    end
  end

  defp render_snapshot(_snapshot, _issue), do: {:error, :invalid_dispatch_snapshot}

  defp snapshot_brief(snapshot, issue, descriptor) do
    work_item = snapshot_value(snapshot, :work_item, work_item_context(issue))

    %{
      work_item: %{
        identifier: snapshot_value(work_item, :identifier, issue.identifier),
        title: snapshot_value(work_item, :title, issue.title),
        url: snapshot_value(work_item, :url, issue.url),
        kind: snapshot_value(work_item, :kind, issue.kind)
      },
      live_head: snapshot_value(snapshot, :live_head, nil),
      unresolved_feedback: %{
        source: "sidecar",
        count: get_in(descriptor, [:regions, "unresolved_threads", :count])
      },
      feedback: %{
        source: "sidecar",
        counts: Map.new(descriptor.regions, fn {name, entry} -> {name, entry.count} end)
      },
      evidence_sidecar: %{
        path_env: "SYMPHONY_ORCHESTRATION_EVIDENCE",
        format: descriptor.format,
        schema_version: descriptor.schema_version,
        bytes: descriptor.bytes,
        sha256: descriptor.sha256,
        required_regions: descriptor.required_regions,
        regions: descriptor.regions
      },
      focused_verification: ["git diff --check 및 변경 파일을 직접 다루는 focused verification만 실행"],
      stop_conditions: [
        "remote head drift, broker snapshot API failure, credible focused verification 부재 시 중단하고 보고",
        "GitHub를 조회하거나 변경하지 않음"
      ]
    }
  end

  defp snapshot_value(snapshot, key, default) do
    Map.get(snapshot, key) || Map.get(snapshot, Atom.to_string(key)) || default
  end

  defp normalize_snapshot_rendered(rendered, issue, evidence, descriptor) do
    if byte_size(rendered) <= @max_bytes do
      {:ok, rendered,
       %{
         source: :broker,
         bytes: byte_size(rendered),
         lane: issue.state,
         evidence: Map.put(descriptor, :content, evidence)
       }}
    else
      {:error, {:orchestration_brief_too_large, byte_size(rendered)}}
    end
  end

  defp normalize_generated({:ok, brief}, issue) when is_map(brief) do
    rendered = render(brief)

    if byte_size(rendered) <= @max_bytes do
      {:ok, rendered, %{source: :broker, bytes: byte_size(rendered), lane: issue.state}}
    else
      {:error, {:orchestration_brief_too_large, byte_size(rendered)}}
    end
  end

  defp normalize_generated({:ok, brief}, issue) when is_binary(brief) do
    if byte_size(brief) <= @max_bytes do
      {:ok, brief, %{source: :broker, bytes: byte_size(brief), lane: issue.state}}
    else
      {:error, {:orchestration_brief_too_large, byte_size(brief)}}
    end
  end

  defp normalize_generated({:error, reason}, _issue), do: {:error, reason}
  defp normalize_generated(other, _issue), do: {:error, {:invalid_orchestration_brief_result, other}}

  defp render(brief) do
    [
      {"work_item", Map.get(brief, "work_item") || Map.get(brief, :work_item)},
      {"live_head", Map.get(brief, "live_head") || Map.get(brief, :live_head)},
      {"unresolved_feedback", Map.get(brief, "unresolved_feedback") || Map.get(brief, :unresolved_feedback)},
      {"feedback", Map.get(brief, "feedback") || Map.get(brief, :feedback)},
      {"evidence_sidecar", Map.get(brief, "evidence_sidecar") || Map.get(brief, :evidence_sidecar)},
      {"focused_verification", Map.get(brief, "focused_verification") || Map.get(brief, :focused_verification)},
      {"stop_conditions", Map.get(brief, "stop_conditions") || Map.get(brief, :stop_conditions)}
    ]
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{format_value(value)}" end)
  end

  defp format_value(nil), do: "unknown"
  defp format_value(values) when is_list(values), do: Jason.encode!(values)
  defp format_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_value(value), do: to_string(value)

  defp work_item_context(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      url: issue.url,
      kind: issue.kind
    }
  end
end
