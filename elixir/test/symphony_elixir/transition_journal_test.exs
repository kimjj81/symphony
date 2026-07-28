defmodule SymphonyElixir.TransitionJournalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TransitionJournal
  alias SymphonyElixir.TransitionJournal.{Event, Snapshot}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-transition-journal-#{System.unique_integer([:positive])}")
    path = Path.join(root, "transitions.log")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, path: path}
  end

  test "flushes ordered phases and exposes pending transition state", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)

    assert {:ok, %Event{phase: :received}} =
             TransitionJournal.record(journal, "transition-1", :received, %{issue_id: "github:pr:1"})

    assert {:ok, %Event{phase: :decided}} =
             TransitionJournal.record(journal, "transition-1", :decided, %{to_state: "Review"})

    assert {:noop, :phase_already_recorded} =
             TransitionJournal.record(journal, "transition-1", :decided, %{to_state: "Rework"})

    assert {:ok, %Snapshot{phase: :decided, data: %{issue_id: "github:pr:1", to_state: "Review"}}} =
             TransitionJournal.snapshot(journal, "transition-1")

    assert [%Snapshot{transition_id: "transition-1", phase: :decided}] =
             TransitionJournal.pending(journal)

    assert :ok = TransitionJournal.close(journal)
  end

  test "replays a verified transition after restart and preserves idempotency", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)

    assert {:ok, _event} = TransitionJournal.record(journal, "transition-2", :received)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-2", :decided)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-2", :required_comment_applied)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-2", :projection_applied)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-2", :verified, %{state: "Human Review"})
    assert :ok = TransitionJournal.close(journal)

    {:ok, reopened} = TransitionJournal.start_link(path: path)

    assert [
             %Event{phase: :received},
             %Event{phase: :decided},
             %Event{phase: :required_comment_applied},
             %Event{phase: :projection_applied},
             %Event{phase: :verified}
           ] = TransitionJournal.replay(reopened)

    assert {:ok, %Snapshot{phase: :verified, data: %{state: "Human Review"}}} =
             TransitionJournal.snapshot(reopened, "transition-2")

    assert [] = TransitionJournal.pending(reopened)
    assert {:noop, :already_verified} = TransitionJournal.record(reopened, "transition-2", :projection_applied)
    assert :ok = TransitionJournal.close(reopened)
  end

  test "records retry phases and resumes from the durable checkpoint", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)

    assert {:ok, _event} = TransitionJournal.record(journal, "transition-3", :received)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-3", :decided)

    assert {:ok, _event} =
             TransitionJournal.record(journal, "transition-3", :retrying, %{
               effect: :required_comment,
               reason: :timeout
             })

    assert {:ok, _event} =
             TransitionJournal.record(journal, "transition-3", :required_comment_applied, %{comment_id: 44})

    assert {:ok, %Snapshot{phase: :required_comment_applied, data: data}} =
             TransitionJournal.snapshot(journal, "transition-3")

    assert data.effect == :required_comment
    assert data.reason == :timeout
    assert data.comment_id == 44
    assert :ok = TransitionJournal.close(journal)
  end

  test "records review-thread closeout before publication projection", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)

    assert {:ok, _} = TransitionJournal.record(journal, "publication-closeout", :received)
    assert {:ok, _} = TransitionJournal.record(journal, "publication-closeout", :decided)

    assert {:ok, _} =
             TransitionJournal.record(journal, "publication-closeout", :review_threads_applied, %{resolved: ["thread-1"]})

    assert {:ok, _} = TransitionJournal.record(journal, "publication-closeout", :projection_applied)
    assert :ok = TransitionJournal.close(journal)
  end

  test "rejects skipped phases and a second writer for the same workflow", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)

    assert {:error, {:invalid_phase_transition, nil, :verified}} =
             TransitionJournal.record(journal, "transition-4", :verified)

    assert {:error, {:journal_already_open, expanded_path}} =
             TransitionJournal.start_link(path: path)

    assert expanded_path == Path.expand(path)
    assert :ok = TransitionJournal.close(journal)
  end

  test "recovers the same workflow lock after an ungraceful journal process exit", %{path: path} do
    {:ok, journal} = TransitionJournal.start_link(path: path)
    assert {:ok, _event} = TransitionJournal.record(journal, "transition-killed", :received, %{issue_id: "issue-1"})

    Process.unlink(journal)
    monitor = Process.monitor(journal)
    Process.exit(journal, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^journal, :killed}

    {:ok, reopened} = TransitionJournal.start_link(path: path)
    assert [%Event{transition_id: "transition-killed", phase: :received}] = TransitionJournal.replay(reopened)
    assert :ok = TransitionJournal.close(reopened)
  end
end
