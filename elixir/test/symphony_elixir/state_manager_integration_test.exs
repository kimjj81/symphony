defmodule SymphonyElixir.StateManagerIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AppliedTransition, TransitionIntent, TransitionJournal}

  defmodule MissingCanonicalStateHostedGitClient do
    def preflight, do: :ok
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :missing_canonical_state}

    def create_comment_once(issue_id, body, marker) do
      send(self(), {:missing_canonical_state_comment, issue_id, body, marker})
      :applied
    end

    def apply_state_projection(issue_id, expected_state, target_state) do
      send(self(), {:missing_canonical_state_projection, issue_id, expected_state, target_state})
      {:applied, %{issue_id: issue_id, state: target_state}}
    end
  end

  defmodule AmbiguousCanonicalStateHostedGitClient do
    def preflight, do: :ok

    def fetch_issue_states_by_ids(_issue_ids),
      do: {:error, {:ambiguous_state_labels, ["Review", "Reviewing"]}}

    def create_comment_once(issue_id, body, marker) do
      send(self(), {:ambiguous_canonical_state_comment, issue_id, body, marker})
      :applied
    end

    def apply_state_projection(issue_id, expected_state, target_state) do
      send(self(), {:ambiguous_canonical_state_projection, issue_id, expected_state, target_state})
      {:applied, %{issue_id: issue_id, state: target_state}}
    end
  end

  setup do
    journal_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-state-manager-integration-#{System.unique_integer([:positive])}"
      )

    journal_path = Path.join(journal_root, "transitions.log")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    enable_authoritative_mode!(journal_path)

    assert Config.settings!().state_manager.mode == "authoritative"
    assert is_nil(Process.whereis(TransitionJournal))

    journal =
      start_supervised!(
        {TransitionJournal, name: TransitionJournal, path: journal_path},
        restart: :temporary
      )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn -> File.rm_rf!(journal_root) end)

    {:ok, journal: journal, journal_path: journal_path}
  end

  test "authoritative request comments once, projects, and verifies the journal", %{journal: journal} do
    issue = issue("github:pr:515", "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    intent =
      intent("transition-authoritative", issue,
        kind: :implementation_complete,
        comment_body: "구현과 검증을 완료했습니다."
      )

    assert {:reply, {:ok, %AppliedTransition{from_state: "In Progress", to_state: "Review"}}, state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert %AppliedTransition{transition_id: "transition-authoritative", to_state: "Review"} =
             state.last_transition

    marker = "<!-- sym-transition:transition-authoritative -->"

    assert_receive {:memory_tracker_comment_once, "github:pr:515", "구현과 검증을 완료했습니다.", ^marker}
    assert_receive {:memory_tracker_state_projection, "github:pr:515", "In Progress", "Review"}

    assert {:ok, %{phase: :verified, history: history}} =
             TransitionJournal.snapshot(journal, "transition-authoritative")

    assert Enum.map(history, & &1.phase) == [
             :received,
             :decided,
             :required_comment_applied,
             :projection_applied,
             :verified
           ]
  end

  test "a duplicate transition id is a no-op without repeating external effects", %{journal: journal} do
    issue = issue("github:pr:duplicate", "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    intent =
      intent("transition-duplicate", issue,
        kind: :implementation_complete,
        comment_body: "한 번만 게시합니다."
      )

    assert {:reply, {:ok, %AppliedTransition{}}, state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_comment_once, "github:pr:duplicate", _, _}
    assert_receive {:memory_tracker_state_projection, "github:pr:duplicate", "In Progress", "Review"}

    assert {:reply, {:noop, :already_applied}, ^state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               state
             )

    refute_receive {:memory_tracker_comment_once, "github:pr:duplicate", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:duplicate", _, _}

    assert {:ok, %{phase: :verified, history: history}} =
             TransitionJournal.snapshot(journal, "transition-duplicate")

    assert Enum.count(history, &(&1.phase == :verified)) == 1
  end

  test "refresh-only Forgejo delivery facts are journaled and reject payload reuse", %{journal: journal} do
    intent = %{
      source: :forgejo_webhook,
      kind: :head_updated,
      delivery_id: "forgejo-delivery-42:1",
      issue_id: "forgejo:pr:42",
      head_oid: "head-one"
    }

    assert {:noop, :head_updated} = Orchestrator.request_tracker_intent(intent)
    assert {:noop, :already_applied} = Orchestrator.request_tracker_intent(intent)

    assert {:ok, %{phase: :verified, data: %{refresh_only: true}}} =
             TransitionJournal.snapshot(journal, "forgejo_webhook:forgejo-delivery-42:1")

    assert {:error, {:tracker_delivery_payload_mismatch, "forgejo_webhook:forgejo-delivery-42:1"}} =
             Orchestrator.request_tracker_intent(%{intent | head_oid: "head-two"})
  end

  test "a stale expected state returns a conflict without tracker writes", %{journal: journal} do
    issue = issue("github:pr:stale", "Rework")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    stale_intent =
      intent("transition-stale", issue,
        kind: :implementation_complete,
        expected_state: "In Progress",
        comment_body: "이 댓글은 게시되면 안 됩니다."
      )

    assert {:reply, {:conflict, %{expected_state: "In Progress", current_state: "Rework"}}, %{transition_conflicts: 1}} =
             Orchestrator.handle_call(
               {:transition_request, stale_intent},
               {self(), make_ref()},
               empty_state()
             )

    refute_receive {:memory_tracker_comment_once, "github:pr:stale", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:stale", _, _}

    assert {:ok, %{phase: :verified, data: %{result: :conflict}}} =
             TransitionJournal.snapshot(journal, "transition-stale")
  end

  test "a late worker outcome cannot regress a terminal observation", %{journal: journal} do
    issue = issue("github:pr:terminal", "Done")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    late_intent =
      intent("transition-terminal", issue,
        kind: :clean_review,
        expected_state: "Reviewing",
        comment_body: "완료 상태를 되돌리면 안 됩니다."
      )

    state = empty_state()

    assert {:reply, {:noop, :terminal_state}, ^state} =
             Orchestrator.handle_call(
               {:transition_request, late_intent},
               {self(), make_ref()},
               state
             )

    refute_receive {:memory_tracker_comment_once, "github:pr:terminal", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:terminal", _, _}

    assert {:ok, %{phase: :verified, data: %{result: :noop}}} =
             TransitionJournal.snapshot(journal, "transition-terminal")
  end

  test "Todo planning dispatch receives a verified causation without changing state", %{
    journal: journal
  } do
    issue = %{
      issue("github:issue:planning", "Todo")
      | kind: :issue,
        labels: ["sym:todo", "sym:request-planned"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, %Issue{state: "Todo", labels: labels, metadata: metadata}} =
             Orchestrator.mark_issue_in_progress_for_dispatch_for_test(issue)

    dispatch_id = metadata["symphony_transition_id"]
    assert is_binary(dispatch_id)
    assert metadata["symphony_dispatch_state"] == "Todo"
    assert labels == ["sym:todo", "sym:request-planned"]

    assert {:ok,
            %{
              phase: :verified,
              data: %{
                issue_id: "github:issue:planning",
                kind: :dispatch_planning,
                from_state: "Todo",
                to_state: "Todo"
              }
            }} = TransitionJournal.snapshot(journal, dispatch_id)

    assert Orchestrator.worker_dispatch_lease_id_for_test(issue, nil) =~ dispatch_id
    refute_receive {:memory_tracker_state_projection, "github:issue:planning", _, _}

    request_intent =
      intent("planning-request", issue,
        source: :github_webhook,
        actor: "maintainer",
        kind: {:operator_request, :planned},
        metadata: %{kind: :operator_transition_requested, label: "sym:request-planned"}
      )

    assert {:reply, {:ok, %AppliedTransition{from_state: "Todo", to_state: "Planned"}}, _state} =
             Orchestrator.handle_call(
               {:transition_request, request_intent},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_state_projection, "github:issue:planning", "Todo", "Planned"}
  end

  test "startup replay completes a pending planning dispatch receipt without tracker writes", %{
    journal: journal
  } do
    transition_id = "dispatch:github:issue:planning-replay:todo"

    assert {:ok, _event} =
             TransitionJournal.record(journal, transition_id, :received, %{
               issue_id: "github:issue:planning-replay",
               source: :dispatch,
               from_state: "Todo",
               to_state: "Todo",
               kind: :dispatch_planning,
               effect: :dispatch_receipt
             })

    assert {:noreply, _state} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert {:ok, %{phase: :verified, data: %{effect: :dispatch_receipt}}} =
             TransitionJournal.snapshot(journal, transition_id)

    refute_receive {:memory_tracker_state_projection, "github:issue:planning-replay", _, _}
  end

  test "projection drift never reopens a terminal live pull request", %{journal: journal} do
    issue = %{
      issue("github:pr:merged", "Done")
      | metadata: %{merged: true, physical_state: "closed"}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_verified_state!(journal, "merge-started", issue.id, "Merging")

    state = empty_state()

    assert {:reply, {:noop, :terminal_state}, ^state} =
             Orchestrator.handle_call(
               {:projection_drift, %{issue_id: issue.id, observed_state: nil}},
               {self(), make_ref()},
               state
             )

    refute_receive {:memory_tracker_comment_once, "github:pr:merged", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:merged", _, _}
  end

  test "projection drift restores a manually applied terminal label on an open pull request", %{
    journal: journal
  } do
    issue = %{
      issue("github:pr:open-terminal-label", "Done")
      | metadata: %{merged: false, physical_state: "open"}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_verified_state!(journal, "open-merge-started", issue.id, "Merging")

    assert {:reply, {:ok, %{reconciled: true, state: "Merging"}}, _state} =
             Orchestrator.handle_call(
               {:projection_drift, %{issue_id: issue.id, observed_state: "Done"}},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_comment_once, "github:pr:open-terminal-label", _, _}

    assert_receive {:memory_tracker_state_projection, "github:pr:open-terminal-label", "Done", "Merging"}
  end

  test "webhook drift without committed state is journaled as a no-effect receipt", %{
    journal: journal
  } do
    intent = %{
      source: :github_webhook,
      kind: :state_projection_drift,
      delivery_id: "orphan-drift-delivery",
      issue_id: "github:pr:orphan-drift",
      observed_state: "Waiting"
    }

    assert {:reply, {:noop, :canonical_state_unavailable}, state} =
             Orchestrator.handle_call(
               {:projection_drift, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert {:reply, {:noop, :already_applied}, ^state} =
             Orchestrator.handle_call(
               {:projection_drift, intent},
               {self(), make_ref()},
               state
             )

    assert {:ok,
            %{
              phase: :verified,
              data: %{
                issue_id: "github:pr:orphan-drift",
                kind: :canonical_state_unavailable,
                refresh_only: true
              }
            }} =
             TransitionJournal.snapshot(
               journal,
               "github_webhook:orphan-drift-delivery"
             )

    refute_receive {:memory_tracker_comment_once, "github:pr:orphan-drift", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:orphan-drift", _, _}
  end

  test "state-less drift resumes partial no-effect receipts", %{journal: journal} do
    for phase <- [:received, :decided] do
      delivery_id = "partial-orphan-drift-#{phase}"

      intent = %{
        source: :github_webhook,
        kind: :state_projection_drift,
        delivery_id: delivery_id,
        issue_id: "github:pr:partial-orphan-drift",
        observed_state: "Waiting"
      }

      transition_id = "github_webhook:#{delivery_id}"
      digest = tracker_payload_digest(intent)

      data = %{
        issue_id: intent.issue_id,
        source: :github_webhook,
        kind: :canonical_state_unavailable,
        payload_digest: digest,
        refresh_only: true
      }

      assert {:ok, _} = TransitionJournal.record(journal, transition_id, :received, data)

      if phase == :decided do
        assert {:ok, _} = TransitionJournal.record(journal, transition_id, :decided, data)
      end

      assert {:reply, {:noop, :canonical_state_unavailable}, _state} =
               Orchestrator.handle_call(
                 {:projection_drift, intent},
                 {self(), make_ref()},
                 empty_state()
               )

      assert {:ok, %{phase: :verified, data: %{payload_digest: ^digest}}} =
               TransitionJournal.snapshot(journal, transition_id)
    end

    refute_receive {:memory_tracker_comment_once, "github:pr:partial-orphan-drift", _, _}
    refute_receive {:memory_tracker_state_projection, "github:pr:partial-orphan-drift", _, _}
  end

  test "an invalid operator request is rejected and receives one reconciliation comment" do
    issue = issue("github:pr:invalid-request", "Todo")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    invalid_intent =
      intent("transition-invalid-request", issue,
        source: :tracker_event,
        actor: "maintainer",
        kind: {:operator_request, :merging}
      )

    assert {:reply, {:rejected, {:invalid_operator_transition, "Todo", :merging}}, _state} =
             Orchestrator.handle_call(
               {:transition_request, invalid_intent},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_comment_once, "github:pr:invalid-request", body, rejection_marker}
    assert String.starts_with?(rejection_marker, "<!-- sym-transition:request-rejected:")
    assert body =~ "현재 상태: Todo"
    assert body =~ "invalid_operator_transition"
    refute_receive {:memory_tracker_state_projection, "github:pr:invalid-request", _, _}
  end

  test "startup replay preserves confirmation-review handoff from a received intent", %{journal: journal} do
    issue = issue("github:pr:review-replay", "Reviewing")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    dispatch_id = "dispatch-review-replay"

    assert {:ok, _event} =
             TransitionJournal.record(journal, dispatch_id, :received, %{issue_id: issue.id})

    assert {:ok, _event} =
             TransitionJournal.record(journal, dispatch_id, :decided, %{
               issue_id: issue.id,
               kind: :dispatch_review
             })

    assert {:ok, _event} =
             TransitionJournal.record(journal, dispatch_id, :verified, %{
               issue_id: issue.id,
               kind: :dispatch_review
             })

    assert {:ok, _event} =
             TransitionJournal.record(journal, "transition-review-replay", :received, %{
               issue_id: issue.id,
               source: :worker,
               actor: "symphony-worker",
               expected_state: "Reviewing",
               kind: :review_findings,
               causation_id: "run-review-replay",
               work_item_kind: :pull_request,
               review_attempt: 4,
               review_limit: 3,
               comment_body: "재수정 세트 후 확인 검토 결과를 인계합니다.",
               metadata: %{dispatch_transition_id: dispatch_id}
             })

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())
    assert %AppliedTransition{to_state: "Human Review"} = state.last_transition
    assert_receive {:memory_tracker_state_projection, ^issue_id, "Reviewing", "Human Review"}
    assert {:ok, %{phase: :verified}} = TransitionJournal.snapshot(journal, "transition-review-replay")
  end

  test "startup replay verifies an already projected transition without writing it twice", %{journal: journal} do
    issue = issue("github:pr:projected-replay", "Review")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    id = "transition-projected-replay"

    plan = %{
      issue_id: issue.id,
      from_state: "In Progress",
      to_state: "Review",
      source: :test_worker,
      actor: "symphony-worker",
      kind: :implementation_complete,
      causation_id: "run-projected",
      head_oid: nil,
      comment_body: nil,
      metadata: %{}
    }

    assert {:ok, _} = TransitionJournal.record(journal, id, :received, %{issue_id: issue.id})
    assert {:ok, _} = TransitionJournal.record(journal, id, :decided, plan)
    assert {:ok, _} = TransitionJournal.record(journal, id, :projection_applied, %{projection: %{state: "Review"}})

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())
    assert %AppliedTransition{to_state: "Review"} = state.last_transition
    refute_receive {:memory_tracker_state_projection, ^issue_id, _, _}
    assert {:ok, %{phase: :verified}} = TransitionJournal.snapshot(journal, id)
  end

  test "startup replay quarantines a journal entry from a different hosted-git provider", %{journal: journal} do
    id = "transition-provider-mismatch"

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :received, %{
               issue_id: "github:issue:91",
               source: :worker,
               kind: :implementation_complete
             })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "forgejo",
      tracker_endpoint: "https://forgejo.example/api/v1",
      tracker_owner: "acme",
      tracker_repo: "widgets",
      tracker_write_api_token: "forgejo-write"
    )

    Application.put_env(:symphony_elixir, :forgejo_request_fun, fn _opts ->
      flunk("provider-mismatched replay must not call Forgejo")
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :forgejo_request_fun) end)

    assert {:noreply, %{transition_conflicts: 1}} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert {:ok, %{phase: :verified, data: %{quarantined: true}}} =
             TransitionJournal.snapshot(journal, id)
  end

  test "multiple live request labels are quarantined and reconciled" do
    issue = %{issue("github:pr:request-conflict", "Review") | labels: ["sym:request-rework", "sym:request-merging"]}
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    intent =
      intent("transition-request-conflict", issue,
        source: :github_webhook,
        actor: "maintainer",
        kind: {:operator_request, :rework},
        metadata: %{kind: :operator_transition_requested, label: "sym:request-rework"}
      )

    assert {:reply, {:rejected, {:ambiguous_request_labels, "sym:request-rework", labels}}, _state} =
             Orchestrator.handle_call({:transition_request, intent}, {self(), make_ref()}, empty_state())

    assert labels == ["sym:request-merging", "sym:request-rework"]
    assert_receive {:memory_tracker_comment_once, ^issue_id, body, _marker}
    assert body =~ "상태 전이를 적용하지 않았습니다"
    assert_receive {:memory_tracker_state_projection, ^issue_id, "Review", "Review"}
  end

  test "accepts a mixed-case Forgejo request label through authoritative validation" do
    issue = %{issue("forgejo:pr:request-case", "Human Review") | labels: ["SYM:REQUEST-MERGING"]}
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    intent =
      intent("transition-request-case", issue,
        source: :forgejo_webhook,
        actor: "maintainer",
        kind: {:operator_request, :merging},
        metadata: %{kind: :operator_transition_requested, label: "SYM:REQUEST-MERGING"}
      )

    assert {:reply, {:ok, %{to_state: "Merging"}}, _state} =
             Orchestrator.handle_call({:transition_request, intent}, {self(), make_ref()}, empty_state())

    assert_receive {:memory_tracker_state_projection, ^issue_id, "Human Review", "Merging"}
  end

  test "an unreadable operator request is quarantined and journaled as verified", %{
    journal: journal
  } do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    intent = %TransitionIntent{
      id: "unreadable-operator-request",
      issue_id: "github:pr:unreadable",
      source: :github_webhook,
      actor: "maintainer",
      kind: {:operator_request, :rework},
      causation_id: "delivery-unreadable"
    }

    assert {:reply, {:rejected, {:quarantined, :transition_issue_not_found}}, _state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_comment_once, "github:pr:unreadable", _, _}

    assert {:ok, %{phase: :verified, data: %{result: :rejected}}} =
             TransitionJournal.snapshot(journal, intent.id)
  end

  test "untracked Codex review feedback is a verified no-effect decision", %{
    journal: journal,
    journal_path: journal_path
  } do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      Application.delete_env(:symphony_elixir, :forgejo_client_module)
    end)

    for {tracker_kind, source, issue_id, client_module_key} <- [
          {"github", :github_webhook, "github:pr:untracked-review", :github_client_module},
          {"forgejo", :forgejo_webhook, "forgejo:pr:untracked-review", :forgejo_client_module}
        ] do
      configure_authoritative_hosted_git_tracker!(tracker_kind, journal_path)
      Application.put_env(:symphony_elixir, client_module_key, MissingCanonicalStateHostedGitClient)

      intent = %TransitionIntent{
        id: "#{source}-untracked-review",
        issue_id: issue_id,
        source: source,
        actor: "chatgpt-codex-connector",
        kind: {:operator_request, :rework},
        causation_id: "#{source}-delivery",
        metadata: %{kind: :review_feedback_detected}
      }

      assert {:reply, {:noop, :untracked_review_feedback}, _state} =
               Orchestrator.handle_call(
                 {:transition_request, intent},
                 {self(), make_ref()},
                 empty_state()
               )

      refute_receive {:missing_canonical_state_comment, ^issue_id, _, _}
      refute_receive {:missing_canonical_state_projection, ^issue_id, _, _}

      assert {:ok, %{phase: :verified, data: %{result: :noop, reason: ":untracked_review_feedback"}}} =
               TransitionJournal.snapshot(journal, intent.id)
    end
  end

  test "ambiguous Codex review feedback remains quarantined", %{journal_path: journal_path} do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      Application.delete_env(:symphony_elixir, :forgejo_client_module)
    end)

    for {tracker_kind, source, issue_id, client_module_key} <- [
          {"github", :github_webhook, "github:pr:ambiguous-review", :github_client_module},
          {"forgejo", :forgejo_webhook, "forgejo:pr:ambiguous-review", :forgejo_client_module}
        ] do
      configure_authoritative_hosted_git_tracker!(tracker_kind, journal_path)
      Application.put_env(:symphony_elixir, client_module_key, AmbiguousCanonicalStateHostedGitClient)

      intent = %TransitionIntent{
        id: "#{source}-ambiguous-review",
        issue_id: issue_id,
        source: source,
        actor: "chatgpt-codex-connector",
        kind: {:operator_request, :rework},
        causation_id: "#{source}-ambiguous-delivery",
        metadata: %{kind: :review_feedback_detected}
      }

      expected_reason =
        {:quarantined, {:transition_issue_fetch_failed, {:ambiguous_state_labels, ["Review", "Reviewing"]}}}

      assert {:reply, {:rejected, ^expected_reason}, _state} =
               Orchestrator.handle_call(
                 {:transition_request, intent},
                 {self(), make_ref()},
                 empty_state()
               )

      assert_receive {:ambiguous_canonical_state_comment, ^issue_id, _, _}
      refute_receive {:ambiguous_canonical_state_projection, ^issue_id, _, _}
    end
  end

  test "a non-operator policy rejection is a verified decision", %{journal: journal} do
    issue = issue("github:pr:invalid-worker-kind", "Reviewing")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    intent =
      intent("invalid-worker-kind", issue,
        source: :test_worker,
        kind: :planning_complete
      )

    assert {:reply, {:rejected, {:invalid_transition, "Reviewing", :planning_complete}}, _state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert {:ok, %{phase: :verified, data: %{result: :rejected}}} =
             TransitionJournal.snapshot(journal, intent.id)
  end

  test "worker dispatch leases are stable per attempt and distinct across retries" do
    issue = %{issue("github:pr:worker-lease", "Reviewing") | metadata: %{"symphony_transition_id" => "dispatch-cycle-7"}}

    initial = Orchestrator.worker_dispatch_lease_id_for_test(issue, nil)
    retry_one = Orchestrator.worker_dispatch_lease_id_for_test(issue, 1)

    assert initial == Orchestrator.worker_dispatch_lease_id_for_test(issue, nil)
    assert initial == "worker-dispatch:dispatch-cycle-7:attempt-0"
    assert retry_one == "worker-dispatch:dispatch-cycle-7:attempt-1"
    refute retry_one == initial
  end

  test "startup recovery hands an ambiguous worker dispatch lease to human review", %{journal: journal} do
    issue = issue("github:pr:ambiguous-worker", "Reviewing")
    issue_id = issue.id
    lease_id = "worker-dispatch:dispatch-cycle-8:attempt-0"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, _} = TransitionJournal.record(journal, lease_id, :received, %{issue_id: issue_id})
    assert {:ok, _} = TransitionJournal.record(journal, lease_id, :decided, %{issue_id: issue_id, effect: :worker_dispatch})
    assert {:ok, _} = TransitionJournal.record(journal, lease_id, :projection_applied, %{issue_id: issue_id, effect: :worker_dispatch})

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())
    assert %AppliedTransition{to_state: "Human Review"} = state.last_transition
    assert_receive {:memory_tracker_state_projection, ^issue_id, "Reviewing", "Human Review"}
  end

  test "startup recovery also hands off a verified orphan worker lease", %{journal: journal} do
    issue = issue("github:pr:verified-orphan-worker", "Reviewing")
    issue_id = issue.id
    lease_id = "worker-dispatch:dispatch-cycle-verified:attempt-0"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_worker_lease!(journal, lease_id, issue_id)

    assert {:noreply, state} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert %AppliedTransition{to_state: "Human Review"} = state.last_transition
    assert_receive {:memory_tracker_state_projection, ^issue_id, "Reviewing", "Human Review"}
  end

  test "startup recovery does not hand off a lease with a later verified outcome", %{
    journal: journal
  } do
    issue = issue("github:pr:completed-worker", "Human Review")
    issue_id = issue.id
    lease_id = "worker-dispatch:dispatch-cycle-completed:attempt-0"
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_worker_lease!(journal, lease_id, issue_id)

    outcome_id = "worker-outcome-completed"
    assert {:ok, _} = TransitionJournal.record(journal, outcome_id, :received, %{issue_id: issue_id})

    assert {:ok, _} =
             TransitionJournal.record(journal, outcome_id, :decided, %{
               issue_id: issue_id,
               kind: :clean_review
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, outcome_id, :verified, %{
               issue_id: issue_id,
               kind: :clean_review
             })

    assert {:noreply, state} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert is_nil(state.last_transition)
    refute_receive {:memory_tracker_state_projection, ^issue_id, _, _}
  end

  test "startup recovery fences worker tasks inherited from a previous orchestrator" do
    assert {:ok, worker_pid} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               Process.sleep(:infinity)
             end)

    monitor = Process.monitor(worker_pid)

    assert {:noreply, _state} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert_receive {:DOWN, ^monitor, :process, ^worker_pid, _reason}
  end

  test "startup replay closes a parent transition when its handoff is already verified", %{
    journal: journal
  } do
    issue_id = "github:pr:handoff-crash-window"
    parent_id = "transition-effect-parent"
    handoff_id = "effect-retry-exhausted:#{parent_id}"

    assert {:ok, _} = TransitionJournal.record(journal, parent_id, :received, %{issue_id: issue_id})

    assert {:ok, _} =
             TransitionJournal.record(journal, parent_id, :decided, %{
               issue_id: issue_id,
               from_state: "Reviewing",
               to_state: "Human Review",
               kind: :handoff_required
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, parent_id, :retrying, %{
               issue_id: issue_id,
               handoff_transition_id: handoff_id
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, handoff_id, :received, %{
               issue_id: issue_id,
               causation_id: parent_id
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, handoff_id, :decided, %{
               issue_id: issue_id,
               causation_id: parent_id
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, handoff_id, :verified, %{
               issue_id: issue_id,
               causation_id: parent_id
             })

    assert {:noreply, _state} =
             Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert {:ok, %{phase: :verified, data: %{handoff_transition_id: ^handoff_id}}} =
             TransitionJournal.snapshot(journal, parent_id)
  end

  test "a worker outcome from an earlier dispatch cycle is a verified no-op", %{journal: journal} do
    issue = %{
      issue("github:pr:aba-worker", "Reviewing")
      | metadata: %{"head_oid" => "head-current"}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_dispatch!(journal, "dispatch-cycle-old", issue.id, :dispatch_review)
    record_dispatch!(journal, "dispatch-cycle-current", issue.id, :dispatch_review)

    stale_intent =
      intent("stale-worker-outcome", issue,
        source: :worker,
        kind: :clean_review,
        head_oid: "head-current",
        metadata: %{dispatch_transition_id: "dispatch-cycle-old"}
      )

    assert {:reply, {:noop, :stale_causation}, _state} =
             Orchestrator.handle_call(
               {:transition_request, stale_intent},
               {self(), make_ref()},
               empty_state()
             )

    assert {:ok, %{phase: :verified}} =
             TransitionJournal.snapshot(journal, "stale-worker-outcome")

    refute_receive {:memory_tracker_state_projection, _, _, _}
  end

  test "a pull request worker outcome without a head oid is a verified no-op", %{journal: journal} do
    issue = %{
      issue("github:pr:missing-head", "Reviewing")
      | metadata: %{"head_oid" => "head-current"}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_dispatch!(journal, "dispatch-cycle-head", issue.id, :dispatch_review)

    intent =
      intent("missing-head-worker-outcome", issue,
        source: :worker,
        kind: :clean_review,
        metadata: %{dispatch_transition_id: "dispatch-cycle-head"}
      )

    assert {:reply, {:noop, :missing_head_oid}, _state} =
             Orchestrator.handle_call(
               {:transition_request, intent},
               {self(), make_ref()},
               empty_state()
             )

    assert {:ok, %{phase: :verified}} =
             TransitionJournal.snapshot(journal, "missing-head-worker-outcome")

    refute_receive {:memory_tracker_state_projection, _, _, _}
  end

  test "a broker publication handoff without a confirmed remote head reaches human review", %{journal: journal} do
    issue = %{
      issue("github:pr:publication-handoff", "Rework")
      | metadata: %{"head_oid" => "head-current"}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    handoff =
      intent("broker-publication-handoff", issue,
        source: :orchestrator,
        actor: "symphony-broker",
        kind: :handoff_required,
        head_oid: nil,
        causation_id: nil,
        metadata: %{publication_handoff: true},
        comment_body: "Broker publish를 사람 검토로 인계합니다."
      )

    assert {:reply, {:ok, %AppliedTransition{to_state: "Human Review"}}, _state} =
             Orchestrator.handle_call(
               {:transition_request, handoff},
               {self(), make_ref()},
               empty_state()
             )

    assert_receive {:memory_tracker_state_projection, "github:pr:publication-handoff", "Rework", "Human Review"}
    assert {:ok, %{phase: :verified}} = TransitionJournal.snapshot(journal, "broker-publication-handoff")
  end

  test "startup preserves a pending publication claim instead of handing off an orphan worker lease", %{journal: journal} do
    issue = issue("github:pr:publication-transport-retry", "Reviewing")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_worker_lease!(journal, "worker-dispatch:publication-transport:attempt-0", issue.id)

    publication_id = "publication:#{issue.id}:session-transport"

    record_publication_receipt!(journal, publication_id, publication_data(issue, %{session_id: "session-transport"}), :retrying)

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    assert MapSet.member?(state.publication_pending, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert is_nil(state.last_transition)
    assert {:ok, %{phase: :retrying}} = TransitionJournal.snapshot(journal, publication_id)
    refute_receive {:memory_tracker_state_projection, ^issue_id, _, _}
  end

  test "startup replays a pending publication handoff before verifying its receipt", %{journal: journal} do
    issue = issue("github:pr:publication-handoff-replay", "Rework")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_worker_lease!(journal, "worker-dispatch:publication-handoff:attempt-0", issue.id)

    publication_id = "publication:#{issue.id}:session-handoff"
    transition_id = "broker-publication-handoff:#{issue.id}:session-handoff"

    data =
      publication_data(issue, %{
        session_id: "session-handoff",
        result: :handoff,
        reason: ":publication_rebase_conflict",
        state_transition_id: transition_id,
        provenance: %{live_head_oid: nil, branch: "review-head", integration: :handoff},
        review_thread_closeout: %{
          replied: ["thread-needs-human"],
          needs_human: [{"thread-needs-human", :review_thread_needs_human}]
        }
      })

    record_publication_receipt!(journal, publication_id, data, :projection_applied)

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())
    assert %AppliedTransition{to_state: "Human Review"} = state.last_transition
    assert_receive {:memory_tracker_state_projection, ^issue_id, "Rework", "Human Review"}
    assert {:ok, %{phase: :verified, history: history}} = TransitionJournal.snapshot(journal, publication_id)
    assert Enum.count(history, &(&1.phase == :review_threads_applied)) == 1
    assert {:ok, %{phase: :verified}} = TransitionJournal.snapshot(journal, transition_id)

    assert {:noreply, _state} = Orchestrator.handle_continue(:replay_transition_journal, state)
    refute_receive {:memory_tracker_state_projection, ^issue_id, _, _}
  end

  test "stale publication causation is verified as obsolete and releases the claim", %{journal: journal} do
    issue = issue("github:pr:publication-stale-causation", "Reworking")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record_worker_lease!(journal, "worker-dispatch:publication-stale:attempt-0", issue.id)

    publication_id = "publication:#{issue.id}:session-stale"
    transition_id = "worker:#{issue.id}:session-stale"

    assert {:ok, _} = TransitionJournal.record(journal, transition_id, :received, %{issue_id: issue.id})

    assert {:ok, _} =
             TransitionJournal.record(journal, transition_id, :decided, %{
               issue_id: issue.id,
               kind: :rework_complete,
               result: :noop,
               reason: ":stale_causation"
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, transition_id, :verified, %{
               issue_id: issue.id,
               kind: :rework_complete,
               result: :noop,
               reason: ":stale_causation"
             })

    record_publication_receipt!(
      journal,
      publication_id,
      publication_data(issue, %{session_id: "session-stale", state_transition_id: transition_id}),
      :projection_applied
    )

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())

    refute MapSet.member?(state.publication_pending, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
    assert is_nil(state.last_transition)

    assert {:ok, %{phase: :verified, data: %{result: :obsolete}}} =
             TransitionJournal.snapshot(journal, publication_id)

    refute_receive {:memory_tracker_state_projection, ^issue_id, _, _}
  end

  test "publication recovery trusts only its recorded state transition and retains final provenance", %{journal: journal} do
    issue = issue("github:pr:publication-final-provenance", "Reviewing")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    publication_id = "publication:#{issue.id}:session-provenance"
    transition_id = "worker:#{issue.id}:session-provenance:publication:remote-head"
    final_provenance = %{published_head_oid: "remote-head", live_head_oid: "remote-head", integration: :concurrently_advanced}

    record_publication_receipt!(
      journal,
      publication_id,
      publication_data(issue, %{
        session_id: "session-provenance",
        state_transition_id: transition_id,
        provenance: final_provenance
      }),
      :projection_applied
    )

    wrong_transition_id = "worker:#{issue.id}:session-provenance:publication:wrong-head"
    assert {:ok, _} = TransitionJournal.record(journal, wrong_transition_id, :received, %{issue_id: issue.id})
    assert {:ok, _} = TransitionJournal.record(journal, wrong_transition_id, :decided, %{issue_id: issue.id, kind: :rework_complete})
    assert {:ok, _} = TransitionJournal.record(journal, wrong_transition_id, :verified, %{issue_id: issue.id, kind: :rework_complete})

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, empty_state())
    assert {:ok, %{phase: :retrying}} = TransitionJournal.snapshot(journal, publication_id)
    assert MapSet.member?(state.publication_pending, issue.id)

    assert {:ok, _} = TransitionJournal.record(journal, transition_id, :received, %{issue_id: issue.id})
    assert {:ok, _} = TransitionJournal.record(journal, transition_id, :decided, %{issue_id: issue.id, kind: :rework_complete})
    assert {:ok, _} = TransitionJournal.record(journal, transition_id, :verified, %{issue_id: issue.id, kind: :rework_complete})

    assert {:noreply, state} = Orchestrator.handle_continue(:replay_transition_journal, state)

    assert {:ok, %{phase: :verified, data: %{state_transition_id: ^transition_id, provenance: ^final_provenance}}} =
             TransitionJournal.snapshot(journal, publication_id)

    refute MapSet.member?(state.publication_pending, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
  end

  defp issue(id, state) do
    %Issue{
      id: id,
      identifier: id,
      title: "State manager integration",
      state: state,
      kind: :pull_request
    }
  end

  defp intent(id, issue, overrides) do
    defaults = [
      id: id,
      issue_id: issue.id,
      source: :test_worker,
      actor: "symphony-worker",
      expected_state: issue.state,
      kind: :implementation_complete,
      work_item_kind: issue.kind,
      causation_id: "run-#{id}"
    ]

    struct!(TransitionIntent, Keyword.merge(defaults, overrides))
  end

  defp empty_state do
    %Orchestrator.State{
      transition_conflicts: 0,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp publication_data(issue, overrides) do
    Map.merge(
      %{
        issue_id: issue.id,
        workspace: Path.join(System.tmp_dir!(), "missing-publication-workspace-#{System.unique_integer([:positive])}"),
        base_head_oid: "base-head",
        worker_head_oid: "worker-head",
        branch: "review-head",
        kind: :rework_complete,
        evidence: [],
        findings: [],
        summary_ko: "broker publication recovery",
        session_id: "session-default",
        dispatch_transition_id: "dispatch-publication",
        state_transition_id: "worker:#{issue.id}:session-default",
        result: :published,
        provenance: %{published_head_oid: "worker-head", live_head_oid: "worker-head", integration: :direct}
      },
      overrides
    )
  end

  defp record_publication_receipt!(journal, publication_id, data, terminal_phase) do
    assert {:ok, _} = TransitionJournal.record(journal, publication_id, :received, data)
    assert {:ok, _} = TransitionJournal.record(journal, publication_id, :decided, data)

    case terminal_phase do
      :projection_applied ->
        if is_map(data[:review_thread_closeout]) do
          assert {:ok, _} = TransitionJournal.record(journal, publication_id, :review_threads_applied, data)
        end

        assert {:ok, _} = TransitionJournal.record(journal, publication_id, :projection_applied, data)

      :retrying ->
        assert {:ok, _} = TransitionJournal.record(journal, publication_id, :retrying, data)
    end
  end

  defp record_dispatch!(journal, id, issue_id, kind) do
    assert {:ok, _} = TransitionJournal.record(journal, id, :received, %{issue_id: issue_id})
    assert {:ok, _} = TransitionJournal.record(journal, id, :decided, %{issue_id: issue_id, kind: kind})
    assert {:ok, _} = TransitionJournal.record(journal, id, :verified, %{issue_id: issue_id, kind: kind})
  end

  defp record_verified_state!(journal, id, issue_id, state) do
    assert {:ok, _} = TransitionJournal.record(journal, id, :received, %{issue_id: issue_id})

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :decided, %{
               issue_id: issue_id,
               to_state: state
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :verified, %{
               issue_id: issue_id,
               to_state: state
             })
  end

  defp tracker_payload_digest(intent) do
    :crypto.hash(:sha256, :erlang.term_to_binary(intent))
    |> Base.encode16(case: :lower)
  end

  defp record_worker_lease!(journal, id, issue_id) do
    assert {:ok, _} = TransitionJournal.record(journal, id, :received, %{issue_id: issue_id})

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :decided, %{
               issue_id: issue_id,
               effect: :worker_dispatch
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :projection_applied, %{
               issue_id: issue_id,
               effect: :worker_dispatch
             })

    assert {:ok, _} =
             TransitionJournal.record(journal, id, :verified, %{
               issue_id: issue_id,
               effect: :worker_dispatch
             })
  end

  defp enable_authoritative_mode!(journal_path) do
    workflow_path = Workflow.workflow_file_path()

    updated =
      workflow_path
      |> File.read!()
      |> String.replace(
        "polling:\n",
        "state_manager:\n  mode: authoritative\n  journal_path: #{journal_path}\npolling:\n"
      )

    File.write!(workflow_path, updated)
    :ok = WorkflowStore.force_reload()
  end

  defp configure_authoritative_hosted_git_tracker!("github", journal_path) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    enable_authoritative_mode!(journal_path)
  end

  defp configure_authoritative_hosted_git_tracker!("forgejo", journal_path) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "forgejo",
      tracker_endpoint: "https://forgejo.example/api/v1",
      tracker_api_token: "token",
      tracker_owner: "acme",
      tracker_repo: "widgets",
      tracker_project_slug: nil
    )

    enable_authoritative_mode!(journal_path)
  end
end
