defmodule SymphonyElixir.TransitionIntent do
  @moduledoc """
  Tracker-independent request for a workflow state transition.

  Callers report facts and semantic outcomes through `kind`; they never select
  an arbitrary target tracker state.
  """

  @type work_item_kind :: :issue | :pull_request | nil

  @type kind ::
          :dispatch_planning
          | :dispatch_implementation
          | :dispatch_review
          | :dispatch_rework
          | :dispatch_merging
          | :planning_complete
          | :implementation_complete
          | :rework_complete
          | :clean_review
          | :review_findings
          | :merge_ready
          | :merge_observed
          | :closed_unmerged
          | :blocked
          | :handoff_required
          | :children_completed
          | {:operator_request, atom() | String.t()}

  @enforce_keys [:id, :issue_id, :source, :kind]
  defstruct [
    :id,
    :issue_id,
    :source,
    :actor,
    :expected_state,
    :kind,
    :head_oid,
    :causation_id,
    :work_item_kind,
    :review_attempt,
    :review_limit,
    :comment_body,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          issue_id: String.t(),
          source: atom() | String.t(),
          actor: String.t() | nil,
          expected_state: String.t() | nil,
          kind: kind(),
          head_oid: String.t() | nil,
          causation_id: String.t() | nil,
          work_item_kind: work_item_kind(),
          review_attempt: pos_integer() | nil,
          review_limit: pos_integer() | nil,
          comment_body: String.t() | nil,
          metadata: map()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attributes) when is_list(attributes) do
    attributes
    |> Map.new()
    |> new()
  end

  def new(attributes) when is_map(attributes) do
    attributes = normalize_keys(attributes)

    with :ok <- require_string(attributes, :id),
         :ok <- require_string(attributes, :issue_id),
         :ok <- require_value(attributes, :source),
         :ok <- require_value(attributes, :kind),
         :ok <- validate_optional_string(attributes, :expected_state),
         :ok <- validate_optional_positive_integer(attributes, :review_attempt),
         :ok <- validate_optional_positive_integer(attributes, :review_limit),
         :ok <- validate_metadata(attributes) do
      {:ok, struct(__MODULE__, attributes)}
    end
  end

  def new(_attributes), do: {:error, :invalid_attributes}

  defp normalize_keys(attributes) do
    allowed_keys = Map.keys(__struct__()) -- [:__struct__]

    Map.new(attributes, fn
      {key, value} when is_binary(key) -> {matching_key(key, allowed_keys), value}
      pair -> pair
    end)
    |> Map.take(allowed_keys)
  end

  defp matching_key(key, allowed_keys) do
    Enum.find(allowed_keys, key, &(Atom.to_string(&1) == key))
  end

  defp require_string(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp require_value(attributes, key) do
    if is_nil(Map.get(attributes, key)), do: {:error, {:missing_field, key}}, else: :ok
  end

  defp validate_optional_string(attributes, key) do
    case Map.get(attributes, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp validate_optional_positive_integer(attributes, key) do
    case Map.get(attributes, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp validate_metadata(attributes) do
    if is_map(Map.get(attributes, :metadata, %{})), do: :ok, else: {:error, {:invalid_field, :metadata}}
  end
end
