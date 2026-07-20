defmodule SymphonyElixir.WorkflowStatePolicy do
  @moduledoc """
  Pure policy for converting semantic transition intents into tracker states.

  The policy is deliberately independent from tracker clients and process
  state. Terminal states are monotonic: stale automated outcomes become a
  successful no-op instead of regressing completed work.
  """

  alias SymphonyElixir.{TransitionIntent, TransitionPlan}

  @states [
    "Todo",
    "Planned",
    "In Progress",
    "Review",
    "Reviewing",
    "Human Review",
    "Waiting",
    "Rework",
    "Reworking",
    "Merging",
    "Done",
    "Canceled",
    "Duplicate"
  ]
  @terminal_states MapSet.new(["Done", "Canceled", "Cancelled", "Closed", "Duplicate"])

  @type decision ::
          {:ok, TransitionPlan.t()}
          | {:noop, atom()}
          | {:conflict, map()}
          | {:rejected, term()}

  @spec states() :: [String.t()]
  def states, do: @states

  @spec terminal_state?(String.t() | nil) :: boolean()
  def terminal_state?(state) when is_binary(state), do: MapSet.member?(@terminal_states, state)
  def terminal_state?(_state), do: false

  @spec decide(String.t(), TransitionIntent.t()) :: decision()
  def decide(current_state, %TransitionIntent{} = intent) when is_binary(current_state) do
    cond do
      terminal_state?(current_state) and not reopen_intent?(intent) ->
        {:noop, :terminal_state}

      not is_nil(intent.expected_state) and intent.expected_state != current_state ->
        expected_state_decision(current_state, intent)

      true ->
        decide_matching_state(current_state, intent)
    end
  end

  def decide(_current_state, %TransitionIntent{}), do: {:rejected, :missing_current_state}

  @spec target_state(String.t(), TransitionIntent.t()) :: {:ok, String.t()} | {:error, term()}
  def target_state(current_state, %TransitionIntent{} = intent) do
    case transition_target(current_state, intent) do
      target when is_binary(target) -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expected_state_decision(current_state, intent) do
    case transition_target(intent.expected_state, intent) do
      ^current_state -> {:noop, :already_applied}
      _ -> {:conflict, %{expected_state: intent.expected_state, current_state: current_state}}
    end
  end

  defp decide_matching_state(current_state, intent) do
    case transition_target(current_state, intent) do
      target_state when is_binary(target_state) ->
        {:ok, TransitionPlan.from_intent(current_state, target_state, intent)}

      {:error, reason} ->
        {:rejected, reason}
    end
  end

  defp transition_target("Planned", %TransitionIntent{kind: :dispatch_implementation}), do: "In Progress"
  defp transition_target("Review", %TransitionIntent{kind: :dispatch_review, work_item_kind: :pull_request}), do: "Reviewing"
  defp transition_target("Review", %TransitionIntent{kind: :dispatch_review, work_item_kind: nil}), do: "Reviewing"
  defp transition_target("Rework", %TransitionIntent{kind: :dispatch_rework}), do: "Reworking"
  defp transition_target("Todo", %TransitionIntent{kind: :planning_complete}), do: "Human Review"
  defp transition_target("In Progress", %TransitionIntent{kind: :implementation_complete}), do: "Review"
  defp transition_target("Reworking", %TransitionIntent{kind: :rework_complete}), do: "Review"
  defp transition_target("Reviewing", %TransitionIntent{kind: :clean_review}), do: "Human Review"

  defp transition_target("Reviewing", %TransitionIntent{kind: :review_findings} = intent) do
    if final_review_attempt?(intent), do: "Human Review", else: "Rework"
  end

  defp transition_target("Merging", %TransitionIntent{kind: :merge_ready}), do: "Done"
  defp transition_target("Merging", %TransitionIntent{kind: :merge_observed}), do: "Done"

  defp transition_target(current_state, %TransitionIntent{kind: :children_completed}) do
    if terminal_state?(current_state), do: current_state, else: "Done"
  end

  defp transition_target(current_state, %TransitionIntent{kind: :closed_unmerged}) do
    if terminal_state?(current_state), do: current_state, else: "Canceled"
  end

  defp transition_target(current_state, %TransitionIntent{kind: kind}) when kind in [:blocked, :handoff_required] do
    if terminal_state?(current_state), do: current_state, else: "Human Review"
  end

  defp transition_target(current_state, %TransitionIntent{kind: {:operator_request, request}}) do
    operator_target(current_state, normalize_request(request))
  end

  defp transition_target(current_state, %TransitionIntent{kind: kind}), do: {:error, {:invalid_transition, current_state, kind}}

  defp operator_target(current_state, :planned) when current_state in ["Todo", "Human Review"], do: "Planned"
  defp operator_target(current_state, :rework) when current_state in ["Review", "Reviewing", "Human Review"], do: "Rework"
  defp operator_target(current_state, :merging) when current_state in ["Human Review", "Waiting"], do: "Merging"
  defp operator_target(current_state, :human_review) when current_state in ["Todo", "Planned", "In Progress", "Review", "Reviewing", "Waiting", "Rework", "Reworking", "Merging"], do: "Human Review"
  defp operator_target(current_state, :canceled), do: if(terminal_state?(current_state), do: current_state, else: "Canceled")
  defp operator_target(current_state, :duplicate), do: if(terminal_state?(current_state), do: current_state, else: "Duplicate")
  defp operator_target(current_state, :reopen) when current_state in ["Done", "Canceled", "Cancelled", "Closed", "Duplicate"], do: "Human Review"
  defp operator_target(current_state, request), do: {:error, {:invalid_operator_transition, current_state, request}}

  defp normalize_request(request) when is_atom(request), do: request

  defp normalize_request(request) when is_binary(request) do
    request
    |> String.trim()
    |> String.downcase()
    |> String.replace(["sym:request-", "request-"], "")
    |> String.replace("-", "_")
    |> case do
      "planned" -> :planned
      "rework" -> :rework
      "merging" -> :merging
      "human_review" -> :human_review
      "canceled" -> :canceled
      "duplicate" -> :duplicate
      "reopen" -> :reopen
      _ -> :unknown
    end
  end

  defp normalize_request(_request), do: :unknown

  defp reopen_intent?(%TransitionIntent{kind: {:operator_request, request}}), do: normalize_request(request) == :reopen
  defp reopen_intent?(_intent), do: false

  defp final_review_attempt?(%TransitionIntent{review_attempt: attempt, review_limit: limit}) when is_integer(attempt) and is_integer(limit), do: attempt >= limit
  defp final_review_attempt?(_intent), do: false
end
