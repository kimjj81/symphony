defmodule SymphonyElixir.WorkerOutcomeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkerOutcome

  test "accepts a complete rework thread update" do
    assert {:ok, %WorkerOutcome{kind: :rework_complete, review_thread_updates: [update]}} =
             WorkerOutcome.new(%{
               kind: "rework_complete",
               summary_ko: "수정을 완료했습니다.",
               evidence: ["focused test passed"],
               head_oid: "abc123",
               findings: [],
               review_thread_updates: [
                 %{
                   thread_ref: "opaque-thread-id",
                   disposition: "fixed",
                   reply_ko: "수정했고 검증을 통과했습니다.",
                   evidence: ["mix test"]
                 }
               ]
             })

    assert update.thread_ref == "opaque-thread-id"
  end

  test "rejects malformed, duplicate, or non-rework thread updates" do
    base = %{
      kind: "rework_complete",
      summary_ko: "수정을 완료했습니다.",
      evidence: [],
      head_oid: "abc123",
      findings: []
    }

    invalid = %{thread_ref: "thread-1", disposition: "fixed", reply_ko: "", evidence: []}
    assert {:error, :invalid_review_thread_updates} = WorkerOutcome.new(Map.put(base, :review_thread_updates, [invalid]))
    assert {:error, :invalid_review_thread_updates} = WorkerOutcome.new(Map.put(base, :review_thread_updates, ["invalid"]))

    duplicate = %{thread_ref: "thread-1", disposition: "fixed", reply_ko: "수정했습니다.", evidence: []}
    assert {:error, :invalid_review_thread_updates} = WorkerOutcome.new(Map.put(base, :review_thread_updates, [duplicate, duplicate]))

    assert {:error, :review_thread_updates_only_allowed_for_rework} =
             WorkerOutcome.new(Map.merge(base, %{kind: "implementation_complete", review_thread_updates: [duplicate]}))
  end
end
