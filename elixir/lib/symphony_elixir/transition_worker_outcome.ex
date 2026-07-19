defmodule SymphonyElixir.WorkerOutcome do
  @moduledoc """
  Structured result returned by a worker instead of tracker mutations.
  """

  @kinds [
    :planning_complete,
    :implementation_complete,
    :rework_complete,
    :clean_review,
    :review_findings,
    :merge_ready,
    :blocked,
    :handoff_required
  ]

  @enforce_keys [:kind, :summary_ko]
  defstruct [:kind, :summary_ko, :head_oid, evidence: [], findings: [], metadata: %{}]

  @type kind ::
          :planning_complete
          | :implementation_complete
          | :rework_complete
          | :clean_review
          | :review_findings
          | :merge_ready
          | :blocked
          | :handoff_required

  @type t :: %__MODULE__{
          kind: kind(),
          summary_ko: String.t(),
          evidence: [term()],
          head_oid: String.t() | nil,
          findings: [term()],
          metadata: map()
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attributes) when is_list(attributes), do: attributes |> Map.new() |> new()

  def new(attributes) when is_map(attributes) do
    normalized = normalize_attributes(attributes)

    with kind when kind in @kinds <- Map.get(normalized, :kind),
         summary when is_binary(summary) and summary != "" <- Map.get(normalized, :summary_ko),
         evidence when is_list(evidence) <- Map.get(normalized, :evidence, []),
         findings when is_list(findings) <- Map.get(normalized, :findings, []),
         metadata when is_map(metadata) <- Map.get(normalized, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         kind: kind,
         summary_ko: summary,
         evidence: evidence,
         head_oid: Map.get(normalized, :head_oid),
         findings: findings,
         metadata: metadata
       }}
    else
      _ -> {:error, :invalid_worker_outcome}
    end
  end

  def new(_attributes), do: {:error, :invalid_worker_outcome}

  defp normalize_attributes(attributes) do
    %{
      kind: attributes |> fetch_attribute(:kind) |> normalize_kind(),
      summary_ko: fetch_attribute(attributes, :summary_ko),
      evidence: fetch_attribute(attributes, :evidence, []),
      head_oid: fetch_attribute(attributes, :head_oid),
      findings: fetch_attribute(attributes, :findings, []),
      metadata: fetch_attribute(attributes, :metadata, %{})
    }
  end

  defp fetch_attribute(attributes, key, default \\ nil) do
    case Map.fetch(attributes, key) do
      {:ok, value} -> value
      :error -> Map.get(attributes, Atom.to_string(key), default)
    end
  end

  defp normalize_kind(kind) when kind in @kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find(@kinds, &(Atom.to_string(&1) == kind))
  end

  defp normalize_kind(_kind), do: nil
end
