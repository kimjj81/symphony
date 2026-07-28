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
  defstruct [:kind, :summary_ko, :head_oid, evidence: [], findings: [], review_thread_updates: [], metadata: %{}]

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
          review_thread_updates: [map()],
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
         review_thread_updates when is_list(review_thread_updates) <- Map.get(normalized, :review_thread_updates, []),
         :ok <- validate_review_thread_updates(kind, review_thread_updates),
         metadata when is_map(metadata) <- Map.get(normalized, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         kind: kind,
         summary_ko: summary,
         evidence: evidence,
         head_oid: Map.get(normalized, :head_oid),
         findings: findings,
         review_thread_updates: review_thread_updates,
         metadata: metadata
       }}
    else
      {:error, reason} -> {:error, reason}
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
      review_thread_updates: fetch_attribute(attributes, :review_thread_updates, []),
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

  defp validate_review_thread_updates(:rework_complete, updates) do
    with true <- Enum.all?(updates, &valid_review_thread_update?/1),
         refs <- Enum.map(updates, &fetch_thread_update(&1, :thread_ref)),
         true <- length(refs) == MapSet.size(MapSet.new(refs)) do
      :ok
    else
      _ -> {:error, :invalid_review_thread_updates}
    end
  end

  defp validate_review_thread_updates(_kind, []), do: :ok
  defp validate_review_thread_updates(_kind, _updates), do: {:error, :review_thread_updates_only_allowed_for_rework}

  defp valid_review_thread_update?(update) when is_map(update) do
    thread_ref = fetch_thread_update(update, :thread_ref)
    disposition = fetch_thread_update(update, :disposition)
    reply_ko = fetch_thread_update(update, :reply_ko)
    evidence = fetch_thread_update(update, :evidence)

    is_binary(thread_ref) and thread_ref != "" and disposition in ["fixed", "needs_human"] and
      is_binary(reply_ko) and reply_ko != "" and is_list(evidence) and Enum.all?(evidence, &is_binary/1)
  end

  defp valid_review_thread_update?(_update), do: false

  defp fetch_thread_update(update, key) do
    Map.get(update, key) || Map.get(update, Atom.to_string(key))
  end
end
