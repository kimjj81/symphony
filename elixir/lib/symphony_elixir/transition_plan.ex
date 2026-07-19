defmodule SymphonyElixir.TransitionPlan do
  @moduledoc """
  Side-effect-free transition decision produced by `WorkflowStatePolicy`.
  """

  alias SymphonyElixir.TransitionIntent

  @enforce_keys [:id, :issue_id, :from_state, :to_state, :source, :kind]
  defstruct [
    :id,
    :issue_id,
    :from_state,
    :to_state,
    :source,
    :actor,
    :kind,
    :head_oid,
    :causation_id,
    :comment_body,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          issue_id: String.t(),
          from_state: String.t(),
          to_state: String.t(),
          source: atom() | String.t(),
          actor: String.t() | nil,
          kind: TransitionIntent.kind(),
          head_oid: String.t() | nil,
          causation_id: String.t() | nil,
          comment_body: String.t() | nil,
          metadata: map()
        }

  @spec from_intent(String.t(), String.t(), TransitionIntent.t()) :: t()
  def from_intent(from_state, to_state, %TransitionIntent{} = intent) do
    %__MODULE__{
      id: intent.id,
      issue_id: intent.issue_id,
      from_state: from_state,
      to_state: to_state,
      source: intent.source,
      actor: intent.actor,
      kind: intent.kind,
      head_oid: intent.head_oid,
      causation_id: intent.causation_id,
      comment_body: intent.comment_body,
      metadata: intent.metadata
    }
  end
end
