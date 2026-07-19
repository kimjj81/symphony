defmodule SymphonyElixir.AppliedTransition do
  @moduledoc """
  Verified result of applying a `TransitionPlan` to a tracker projection.
  """

  alias SymphonyElixir.TransitionPlan

  @enforce_keys [:transition_id, :issue_id, :from_state, :to_state, :kind, :applied_at]
  defstruct [
    :transition_id,
    :issue_id,
    :from_state,
    :to_state,
    :kind,
    :applied_at,
    :head_oid,
    journal_phase: :verified,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          transition_id: String.t(),
          issue_id: String.t(),
          from_state: String.t(),
          to_state: String.t(),
          kind: term(),
          applied_at: DateTime.t(),
          head_oid: String.t() | nil,
          journal_phase: :verified,
          metadata: map()
        }

  @spec from_plan(TransitionPlan.t(), keyword()) :: t()
  def from_plan(%TransitionPlan{} = plan, opts \\ []) do
    %__MODULE__{
      transition_id: plan.id,
      issue_id: plan.issue_id,
      from_state: plan.from_state,
      to_state: plan.to_state,
      kind: plan.kind,
      applied_at: Keyword.get_lazy(opts, :applied_at, &DateTime.utc_now/0),
      head_oid: plan.head_oid,
      metadata: Map.merge(plan.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end
end
