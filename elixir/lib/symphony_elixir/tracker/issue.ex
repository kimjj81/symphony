defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized tracker work item representation used by the orchestrator.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :kind,
    metadata: %{},
    blocked_by: [],
    labels: [],
    dispatchable: nil,
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type kind :: :issue | :pull_request | nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          kind: kind(),
          metadata: map(),
          blocked_by: [map()],
          labels: [String.t()],
          dispatchable: boolean() | nil,
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{} = issue, required_labels) when is_list(required_labels) do
    dispatchable?(issue) and assigned_to_worker?(issue) and required_labels_present?(issue, required_labels)
  end

  defp dispatchable?(%__MODULE__{dispatchable: false}), do: false
  defp dispatchable?(%__MODULE__{}), do: true

  defp assigned_to_worker?(%__MODULE__{assigned_to_worker: false}), do: false
  defp assigned_to_worker?(%__MODULE__{}), do: true

  defp required_labels_present?(%__MODULE__{labels: labels}, required_labels)
       when is_list(labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  defp required_labels_present?(%__MODULE__{}, []), do: true
  defp required_labels_present?(%__MODULE__{}, _required_labels), do: false

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()
end
