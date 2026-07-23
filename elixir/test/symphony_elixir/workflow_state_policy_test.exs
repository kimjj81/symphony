defmodule SymphonyElixir.WorkflowStatePolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AppliedTransition, TransitionIntent, TransitionPlan, WorkerOutcome, WorkflowStatePolicy}

  describe "decide/2" do
    test "exposes the canonical state set and terminal classifier" do
      assert "Reworking" in WorkflowStatePolicy.states()
      assert WorkflowStatePolicy.terminal_state?("Done")
      refute WorkflowStatePolicy.terminal_state?("Review")
      refute WorkflowStatePolicy.terminal_state?(nil)
    end

    test "maps the visible execution lifecycle without tracker side effects" do
      cases = [
        {"Planned", :dispatch_implementation, nil, "In Progress"},
        {"Review", :dispatch_review, :pull_request, "Reviewing"},
        {"Rework", :dispatch_rework, :pull_request, "Reworking"},
        {"Todo", :planning_complete, :issue, "Human Review"},
        {"In Progress", :implementation_complete, :pull_request, "Review"},
        {"Reworking", :rework_complete, :pull_request, "Review"},
        {"Reviewing", :clean_review, :pull_request, "Human Review"},
        {"Reviewing", :review_findings, :pull_request, "Rework"},
        {"Merging", :merge_observed, :pull_request, "Done"},
        {"Review", :closed_unmerged, :pull_request, "Canceled"},
        {"In Progress", :blocked, :pull_request, "Human Review"},
        {"Reworking", :handoff_required, :pull_request, "Human Review"}
      ]

      for {from_state, kind, item_kind, to_state} <- cases do
        intent = intent(kind, expected_state: from_state, work_item_kind: item_kind)

        assert {:ok, %TransitionPlan{from_state: ^from_state, to_state: ^to_state, kind: ^kind}} =
                 WorkflowStatePolicy.decide(from_state, intent)
      end
    end

    test "permits the configured third rework and routes confirmation-review findings to Human Review" do
      intent = intent(:review_findings, expected_state: "Reviewing", review_attempt: 3, review_limit: 3)

      assert {:ok, %TransitionPlan{to_state: "Rework"}} =
               WorkflowStatePolicy.decide("Reviewing", intent)

      confirmation_intent = intent(:review_findings, expected_state: "Reviewing", review_attempt: 4, review_limit: 3)

      assert {:ok, %TransitionPlan{to_state: "Human Review"}} =
               WorkflowStatePolicy.decide("Reviewing", confirmation_intent)
    end

    test "derives parent completion without bypassing terminal-state semantics" do
      assert {:ok, "Done"} =
               WorkflowStatePolicy.target_state("Human Review", intent(:children_completed))

      assert {:ok, "Done"} =
               WorkflowStatePolicy.target_state("Done", intent(:children_completed))
    end

    test "keeps terminal states monotonic when a stale worker outcome arrives" do
      intent = intent(:clean_review, expected_state: "Reviewing")

      for state <- ["Done", "Canceled", "Cancelled", "Closed", "Duplicate"] do
        assert {:noop, :terminal_state} = WorkflowStatePolicy.decide(state, intent)
      end
    end

    test "returns an idempotent no-op when the expected transition is already projected" do
      intent = intent(:implementation_complete, expected_state: "In Progress")

      assert {:noop, :already_applied} = WorkflowStatePolicy.decide("Review", intent)
    end

    test "returns a conflict for a stale expected state with a different observed target" do
      intent = intent(:implementation_complete, expected_state: "In Progress")

      assert {:conflict, %{expected_state: "In Progress", current_state: "Rework"}} =
               WorkflowStatePolicy.decide("Rework", intent)
    end

    test "rejects invalid edges and issue review dispatch" do
      assert {:rejected, {:invalid_transition, "Review", :implementation_complete}} =
               WorkflowStatePolicy.decide("Review", intent(:implementation_complete, expected_state: "Review"))

      assert {:rejected, {:invalid_transition, "Review", :dispatch_review}} =
               WorkflowStatePolicy.decide(
                 "Review",
                 intent(:dispatch_review, expected_state: "Review", work_item_kind: :issue)
               )

      assert {:rejected, {:invalid_transition, "Todo", :dispatch_planning}} =
               WorkflowStatePolicy.decide(
                 "Todo",
                 intent(:dispatch_planning, expected_state: "Todo", work_item_kind: :issue)
               )

      assert {:rejected, :missing_current_state} =
               WorkflowStatePolicy.decide(nil, intent(:clean_review))

      assert {:ok, "Reviewing"} =
               WorkflowStatePolicy.target_state(
                 "Review",
                 intent(:dispatch_review, work_item_kind: nil)
               )

      assert {:error, {:invalid_transition, "Review", :implementation_complete}} =
               WorkflowStatePolicy.target_state("Review", intent(:implementation_complete))
    end

    test "accepts operator request labels only across explicit edges" do
      assert {:ok, %TransitionPlan{to_state: "Planned"}} =
               WorkflowStatePolicy.decide(
                 "Human Review",
                 intent({:operator_request, "sym:request-planned"}, expected_state: "Human Review")
               )

      assert {:ok, %TransitionPlan{to_state: "Human Review"}} =
               WorkflowStatePolicy.decide(
                 "Done",
                 intent({:operator_request, :reopen}, expected_state: "Done")
               )

      assert {:rejected, {:invalid_operator_transition, "In Progress", :merging}} =
               WorkflowStatePolicy.decide(
                 "In Progress",
                 intent({:operator_request, :merging}, expected_state: "In Progress")
               )

      accepted = [
        {"Review", "request-rework", "Rework"},
        {"Waiting", "sym:request-merging", "Merging"},
        {"Merging", "human-review", "Human Review"},
        {"In Progress", "CANCELED", "Canceled"},
        {"Review", "sym:request-duplicate", "Duplicate"}
      ]

      for {current, request, target} <- accepted do
        assert {:ok, %TransitionPlan{to_state: ^target}} =
                 WorkflowStatePolicy.decide(
                   current,
                   intent({:operator_request, request}, expected_state: current)
                 )
      end

      assert {:rejected, {:invalid_operator_transition, "Review", :unknown}} =
               WorkflowStatePolicy.decide(
                 "Review",
                 intent({:operator_request, "sym:request-not-real"}, expected_state: "Review")
               )

      assert {:rejected, {:invalid_operator_transition, "Review", :unknown}} =
               WorkflowStatePolicy.decide(
                 "Review",
                 intent({:operator_request, 123}, expected_state: "Review")
               )

      assert {:ok, %TransitionPlan{to_state: "Human Review"}} =
               WorkflowStatePolicy.decide(
                 "Done",
                 intent({:operator_request, "sym:request-reopen"}, expected_state: "Done")
               )
    end

    test "moves merge readiness to Done after the brokered merge" do
      assert {:ok, %TransitionPlan{from_state: "Merging", to_state: "Done"}} =
               WorkflowStatePolicy.decide("Merging", intent(:merge_ready, expected_state: "Merging"))
    end
  end

  test "TransitionIntent validates required identity and review fields" do
    assert {:ok, %TransitionIntent{id: "transition-1", kind: :clean_review}} =
             TransitionIntent.new(%{
               "id" => "transition-1",
               "issue_id" => "github:pr:1",
               "source" => "worker",
               "kind" => :clean_review,
               "review_attempt" => 1,
               "metadata" => %{"delivery_id" => "delivery-1"}
             })

    assert {:error, {:invalid_field, :review_attempt}} =
             TransitionIntent.new(id: "transition-1", issue_id: "github:pr:1", source: :worker, kind: :clean_review, review_attempt: 0)

    assert {:ok, %TransitionIntent{expected_state: "Review", review_limit: 3}} =
             TransitionIntent.new(
               id: "transition-2",
               issue_id: "github:pr:2",
               source: :worker,
               kind: :clean_review,
               expected_state: "Review",
               review_limit: 3
             )

    valid = %{id: "transition-3", issue_id: "github:pr:3", source: :worker, kind: :clean_review}

    assert {:error, :invalid_attributes} = TransitionIntent.new(:invalid)
    assert {:error, {:invalid_field, :id}} = TransitionIntent.new(%{valid | id: ""})
    assert {:error, {:invalid_field, :issue_id}} = TransitionIntent.new(%{valid | issue_id: nil})
    assert {:error, {:missing_field, :source}} = TransitionIntent.new(%{valid | source: nil})
    assert {:error, {:missing_field, :kind}} = TransitionIntent.new(%{valid | kind: nil})

    assert {:error, {:invalid_field, :expected_state}} =
             TransitionIntent.new(Map.put(valid, :expected_state, ""))

    assert {:error, {:invalid_field, :review_limit}} =
             TransitionIntent.new(Map.put(valid, :review_limit, 0))

    assert {:error, {:invalid_field, :metadata}} =
             TransitionIntent.new(Map.put(valid, :metadata, []))

    assert {:ok, %TransitionIntent{id: "transition-4"}} =
             TransitionIntent.new(Map.put(valid, "unknown_key", true) |> Map.put(:id, "transition-4"))
  end

  test "WorkerOutcome accepts JSON-shaped semantic outcomes" do
    assert :clean_review in WorkerOutcome.kinds()

    assert {:ok,
            %WorkerOutcome{
              kind: :review_findings,
              summary_ko: "수정이 필요한 항목이 있습니다.",
              findings: [%{"path" => "lib/example.ex"}]
            }} =
             WorkerOutcome.new(%{
               "kind" => "review_findings",
               "summary_ko" => "수정이 필요한 항목이 있습니다.",
               "evidence" => ["mix test"],
               "findings" => [%{"path" => "lib/example.ex"}]
             })

    assert {:error, :invalid_worker_outcome} =
             WorkerOutcome.new(%{"kind" => "done", "summary_ko" => "임의 상태를 쓸 수 없습니다."})

    assert {:ok, %WorkerOutcome{kind: :clean_review}} =
             WorkerOutcome.new(kind: :clean_review, summary_ko: "검토 완료")

    for invalid <- [
          :invalid,
          %{kind: 123, summary_ko: "요약"},
          %{kind: :clean_review, summary_ko: ""},
          %{kind: :clean_review, summary_ko: "요약", evidence: :invalid},
          %{kind: :clean_review, summary_ko: "요약", findings: :invalid},
          %{kind: :clean_review, summary_ko: "요약", metadata: :invalid}
        ] do
      assert {:error, :invalid_worker_outcome} = WorkerOutcome.new(invalid)
    end
  end

  test "AppliedTransition preserves the verified plan identity" do
    plan = TransitionPlan.from_intent("Reviewing", "Human Review", intent(:clean_review))
    applied_at = ~U[2026-07-19 00:00:00Z]

    assert %AppliedTransition{
             transition_id: "transition-:clean_review",
             issue_id: "github:pr:515",
             from_state: "Reviewing",
             to_state: "Human Review",
             journal_phase: :verified,
             applied_at: ^applied_at
           } = AppliedTransition.from_plan(plan, applied_at: applied_at)

    assert %AppliedTransition{applied_at: %DateTime{}, metadata: %{verified: true}} =
             AppliedTransition.from_plan(plan, metadata: %{verified: true})

    assert %AppliedTransition{applied_at: %DateTime{}} = AppliedTransition.from_plan(plan)
  end

  defp intent(kind, opts \\ []) do
    struct!(
      TransitionIntent,
      Keyword.merge(
        [
          id: "transition-#{inspect(kind)}",
          issue_id: "github:pr:515",
          source: :worker,
          kind: kind
        ],
        opts
      )
    )
  end
end
