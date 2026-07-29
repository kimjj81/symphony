defmodule SymphonyElixir.BriefedAgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.OrchestrationBrief
  alias SymphonyElixir.TransitionJournal

  test "orchestration brief rejects output larger than 8KB" do
    issue = review_issue("oversize")
    generator = fn _workspace, _issue -> {:ok, String.duplicate("x", 8_193)} end

    assert {:error, {:orchestration_brief_too_large, size}} =
             OrchestrationBrief.generate("/tmp", issue, brief_generator: generator)

    assert size == 8_193
  end

  test "orchestration brief normalizes structured and invalid generator results" do
    issue = review_issue("normalize")

    brief = %{
      lane: "Review",
      live_head: nil,
      unresolved_feedback: [
        %{thread_ref: "thread-1", feedback: "첫 번째 검토 의견"},
        %{thread_ref: "thread-2", feedback: "두 번째 검토 의견"}
      ],
      allowed_scope: ["agent runner"],
      focused_verification: ["mix test focused"],
      stop_conditions: ["head drift"],
      transitions: ["clean -> Human Review"]
    }

    assert {:ok, rendered, %{source: :broker, lane: "Review", bytes: bytes}} =
             OrchestrationBrief.normalize_for_test({:ok, brief}, issue)

    assert byte_size(rendered) == bytes
    assert rendered =~ "live_head: unknown"
    assert rendered =~ "\"thread_ref\":\"thread-1\""
    assert rendered =~ "\"thread_ref\":\"thread-2\""
    refute rendered =~ "lane:"
    refute rendered =~ "allowed_scope:"
    refute rendered =~ "transitions:"

    oversized_map = Map.put(brief, :live_head, String.duplicate("x", 8_193))

    assert {:error, {:orchestration_brief_too_large, _size}} =
             OrchestrationBrief.normalize_for_test({:ok, oversized_map}, issue)

    assert {:error, :generator_failed} =
             OrchestrationBrief.normalize_for_test({:error, :generator_failed}, issue)

    assert {:error, {:invalid_orchestration_brief_result, :unexpected}} =
             OrchestrationBrief.normalize_for_test(:unexpected, issue)
  end

  test "orchestration brief decoder reports missing, malformed, and non-object output" do
    issue = review_issue("decode-errors")

    assert {:error, :missing_orchestration_brief} =
             OrchestrationBrief.decode_for_test(nil, issue)

    assert {:error, {:invalid_orchestration_brief_json, _reason}} =
             OrchestrationBrief.decode_for_test("not-json", issue)

    assert {:error, :invalid_orchestration_brief} =
             OrchestrationBrief.decode_for_test("[]", issue)
  end

  test "orchestration brief renders a broker snapshot without a Codex preflight session" do
    issue = review_issue("broker-snapshot")

    snapshot = %{
      live_head: "abc123",
      top_level_comments: [%{body: "top-level", author: "reviewer"}],
      reviews: [%{body: "summary", state: "CHANGES_REQUESTED", author: "reviewer"}],
      inline_comments: [%{body: "inline", path: "apps/api/core/models.py", line: 12, author: "reviewer"}],
      unresolved_feedback: [%{thread_ref: "thread-1", feedback: "수정 필요"}]
    }

    assert {:ok, rendered, %{source: :broker, lane: "Review"}} =
             OrchestrationBrief.generate("/tmp", issue, snapshot_fetcher: fn _issue_id -> {:ok, snapshot} end)

    assert rendered =~ "live_head: abc123"
    assert rendered =~ "thread-1"
    assert rendered =~ "top-level"
    assert rendered =~ "GitHub를 조회하거나 변경하지 않음"
  end

  test "orchestration brief returns a broker snapshot failure" do
    snapshot_fetcher = fn _issue -> {:error, {:github_api_status, 401, %{}}} end

    assert {:error, {:github_api_status, 401, %{}}} =
             OrchestrationBrief.generate("/tmp", review_issue("broker-failure"), snapshot_fetcher: snapshot_fetcher)
  end

  test "fallback handles an unknown lane deterministically" do
    issue = %{review_issue("unknown-lane") | state: nil}
    fallback = OrchestrationBrief.fallback(issue)

    assert fallback =~ "live_head: unknown"
    assert fallback =~ "broker snapshot unavailable"
    assert fallback =~ "do not query GitHub"
    refute fallback =~ "lane:"
  end

  test "authoritative pull request code outcome hands off when publication inputs are missing" do
    test_root = test_root("implementation-authority")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")

    outcome = %{
      "kind" => "implementation_complete",
      "summary_ko" => "COMPLETE: 구현을 마쳤습니다.",
      "evidence" => ["focused test passed"],
      "head_oid" => "head-550",
      "findings" => []
    }

    codex_binary = write_worker_outcome_codex!(test_root, trace_file, Jason.encode!(outcome))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Reworking", "Merging"]
    )

    enable_authoritative_mode!()

    issue = %{
      review_issue("implementation-authority")
      | state: "In Progress",
        labels: ["sym:in-progress"],
        metadata: %{
          "symphony_dispatch_state" => "Planned",
          "symphony_transition_id" => "dispatch-550"
        }
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})

                 {:ok, "lane: handoff_required\nallowed_scope: read-only preflight\ntransitions: handoff to a human"}
               end,
               state_manager_requester: fn intent ->
                 send(parent, {:worker_outcome, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:brief_lane, "Planned"}

    assert_receive {:worker_outcome,
                    %SymphonyElixir.TransitionIntent{
                      expected_state: "In Progress",
                      source: :orchestrator,
                      kind: :handoff_required,
                      causation_id: "dispatch-550"
                    } = intent}

    assert intent.head_oid == nil
    assert intent.comment_body =~ "publication_preconditions_missing"
    refute intent.comment_body =~ workspace_root

    trace = File.read!(trace_file)
    assert trace =~ "Execution mode: implementation"
    assert trace =~ "Permitted structured outcomes: implementation_complete, blocked, handoff_required"
    assert trace =~ "bootstrap commit with no implementation diff is the starting point"
    assert trace =~ "\"implementation_complete\""
    refute trace =~ "\"clean_review\""
  end

  test "rebase-conflict publication stays pending until the broker handoff transition completes" do
    test_root = test_root("publication-handoff-receipt")
    on_exit(fn -> File.rm_rf(test_root) end)

    remote = Path.join(test_root, "remote.git")
    source = Path.join(test_root, "source")
    publisher = Path.join(test_root, "publisher")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    journal_path = Path.join(test_root, "publication-transitions.log")

    System.cmd("git", ["init", "--bare", remote])
    System.cmd("git", ["init", "-b", "main", source])
    System.cmd("git", ["-C", source, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", source, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source, "README.md"), "base\n")
    System.cmd("git", ["-C", source, "add", "README.md"])
    System.cmd("git", ["-C", source, "commit", "-m", "base"])
    System.cmd("git", ["-C", source, "remote", "add", "origin", remote])
    System.cmd("git", ["-C", source, "push", "-u", "origin", "main"])
    System.cmd("git", ["-C", source, "checkout", "-b", "review-head"])
    System.cmd("git", ["-C", source, "push", "-u", "origin", "review-head"])
    System.cmd("git", ["-C", source, "checkout", "main"])
    System.cmd("git", ["clone", remote, publisher])
    System.cmd("git", ["-C", publisher, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", publisher, "config", "user.email", "test@example.com"])
    {base_head, 0} = System.cmd("git", ["-C", source, "rev-parse", "origin/review-head"])
    base_head = String.trim(base_head)

    codex_binary = write_conflicting_worker_codex!(test_root, trace_file, publisher)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      workspace_strategy: "git_worktree",
      workspace_source: source,
      workspace_base_ref: "origin/main",
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Reworking", "Merging"]
    )

    enable_authoritative_mode!()

    journal =
      start_supervised!(
        {TransitionJournal, name: TransitionJournal, path: journal_path},
        restart: :temporary
      )

    issue = %{
      review_issue("publication-handoff-receipt")
      | state: "In Progress",
        branch_name: "review-head",
        labels: ["sym:in-progress"],
        metadata: %{
          "head_oid" => base_head,
          "symphony_dispatch_state" => "Planned",
          "symphony_transition_id" => "dispatch-publication-handoff"
        }
    }

    parent = self()
    publication_id = "publication:#{issue.id}:thread-worker-turn-worker"

    result =
      AgentRunner.run(issue, nil,
        raise_on_error: false,
        brief_generator: fn _workspace, _brief_issue -> {:ok, "live_head: #{base_head}"} end,
        state_manager_requester: fn intent ->
          send(parent, {:publication_handoff_intent, intent, TransitionJournal.snapshot(journal, publication_id)})
          {:ok, %{}}
        end
      )

    if result != :ok do
      flunk("unexpected AgentRunner result=#{inspect(result)}\n#{File.read!(trace_file)}")
    end

    assert_receive {:publication_handoff_intent,
                    %SymphonyElixir.TransitionIntent{
                      id: "broker-publication-handoff:" <> _,
                      source: :orchestrator,
                      kind: :handoff_required
                    }, {:ok, %{phase: :projection_applied, data: %{result: :handoff}}}}

    assert {:ok, %{phase: :verified, data: %{result: :handoff}}} =
             TransitionJournal.snapshot(journal, publication_id)
  end

  test "a Planned issue projected to In Progress receives the implementation contract" do
    test_root = test_root("planned-issue-implementation")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")

    outcome = %{
      "kind" => "implementation_complete",
      "summary_ko" => "COMPLETE: 일반 issue 구현을 마쳤습니다.",
      "evidence" => ["focused test passed"],
      "head_oid" => nil,
      "findings" => []
    }

    codex_binary = write_worker_outcome_codex!(test_root, trace_file, Jason.encode!(outcome))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    enable_authoritative_mode!()

    issue = %{
      implementation_issue("planned-issue-implementation")
      | state: "In Progress",
        labels: ["sym:in-progress"],
        metadata: %{
          "symphony_dispatch_state" => "Planned",
          "symphony_transition_id" => "dispatch-issue-529"
        }
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               state_manager_requester: fn intent ->
                 send(parent, {:worker_outcome, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:worker_outcome,
                    %SymphonyElixir.TransitionIntent{
                      expected_state: "In Progress",
                      kind: :implementation_complete,
                      work_item_kind: :issue,
                      causation_id: "dispatch-issue-529"
                    }}

    trace = File.read!(trace_file)
    assert trace =~ "Execution mode: implementation"
    assert trace =~ "Implement the approved issue scope"
    assert trace =~ "work_item:"
    assert trace =~ "\"implementation_complete\""
    refute trace =~ "\"planning_complete\""
  end

  test "an In Progress issue without dispatch metadata receives the implementation contract" do
    test_root = test_root("in-progress-issue-implementation")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")

    outcome = %{
      "kind" => "implementation_complete",
      "summary_ko" => "COMPLETE: 이미 진행 중인 일반 issue 구현을 마쳤습니다.",
      "evidence" => ["focused test passed"],
      "head_oid" => nil,
      "findings" => []
    }

    codex_binary = write_worker_outcome_codex!(test_root, trace_file, Jason.encode!(outcome))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true
    )

    enable_authoritative_mode!()

    issue = %{
      implementation_issue("in-progress-issue-implementation")
      | state: "In Progress",
        labels: ["sym:in-progress"],
        metadata: %{"symphony_transition_id" => "dispatch-issue-530"}
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})
                 {:ok, "live_head: unknown\nunresolved_feedback: none"}
               end,
               state_manager_requester: fn intent ->
                 send(parent, {:worker_outcome, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:brief_lane, "In Progress"}

    assert_receive {:worker_outcome,
                    %SymphonyElixir.TransitionIntent{
                      expected_state: "In Progress",
                      kind: :implementation_complete,
                      work_item_kind: :issue,
                      causation_id: "dispatch-issue-530"
                    }}

    assert File.read!(trace_file) =~ "Execution mode: implementation"
  end

  test "an unsupported authoritative lane hands off before preflight or worker start" do
    test_root = test_root("unsupported-authoritative-lane")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true
    )

    enable_authoritative_mode!()

    issue = %{
      implementation_issue("unsupported-authoritative-lane")
      | state: "Waiting",
        labels: ["sym:waiting"],
        metadata: %{"symphony_transition_id" => "dispatch-waiting"}
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _brief_issue ->
                 send(parent, :unexpected_preflight)
                 {:ok, "should not run"}
               end,
               state_manager_requester: fn intent ->
                 send(parent, {:execution_contract_handoff, intent})
                 {:ok, %{}}
               end
             )

    refute_receive :unexpected_preflight

    assert_receive {:execution_contract_handoff,
                    %SymphonyElixir.TransitionIntent{
                      id: "execution-contract-handoff:github:issue:unsupported-authoritative-lane:dispatch-waiting",
                      source: :orchestrator,
                      expected_state: "Waiting",
                      kind: :handoff_required,
                      work_item_kind: :issue,
                      causation_id: "dispatch-waiting",
                      comment_body: body
                    }}

    assert body =~ "preflight와 작업 에이전트를 시작하지 않고"
    assert body =~ "unsupported_execution_lane"
    refute File.exists?(trace_file)
  end

  test "an unsupported legacy lane hands off before preflight or worker start" do
    test_root = test_root("unsupported-legacy-lane")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true
    )

    issue = %{
      implementation_issue("unsupported-legacy-lane")
      | state: "Waiting",
        labels: ["sym:waiting"]
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _brief_issue ->
                 send(parent, :unexpected_preflight)
                 {:ok, "should not run"}
               end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:handoff_state, issue_id, state})
                 :ok
               end
             )

    refute_receive :unexpected_preflight
    assert_receive {:handoff_comment, "github:issue:unsupported-legacy-lane", body}
    assert body =~ "지원하지 않는 Symphony 실행 lane"
    assert_receive {:handoff_state, "github:issue:unsupported-legacy-lane", "Human Review"}
    refute File.exists?(trace_file)
  end

  test "clean review uses one brief and one fresh worker thread before Human Review" do
    test_root = test_root("clean")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      max_turns: 7,
      max_review_verdicts: 3,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("clean")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, ^issue ->
                 send(parent, :brief_generated)
                 {:ok, "lane: Review\nfocused_verification: direct test only"}
               end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Human Review"}]} end
             )

    assert_receive :brief_generated
    refute_receive :brief_generated

    trace = File.read!(trace_file)
    assert count_lines(trace, "RUN:") == 1
    assert count_lines(trace, "THREAD:") == 1
    assert trace =~ "Verification tier: focused"
    assert trace =~ "automatic rework cycle 1 of 3"
    assert trace =~ "returning exactly one structured semantic outcome"
    assert trace =~ "do not query or mutate GitHub"
    refute trace =~ "synchronizing the required Korean tracker comment"
    refute trace =~ "Re-check the live head once before writes"
    refute trace =~ "You are an agent for this repository."
  end

  test "authoritative preflight failure hands off without starting a worker" do
    test_root = test_root("authoritative-preflight-handoff")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Reworking", "Merging"]
    )

    enable_authoritative_mode!()

    issue = %{
      review_issue("authoritative-preflight-handoff")
      | state: "Reworking",
        metadata: %{
          "head_oid" => "head-123",
          "symphony_dispatch_state" => "Rework",
          "symphony_transition_id" => "dispatch-123"
        }
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})
                 {:error, :github_preflight_unavailable}
               end,
               state_manager_requester: fn intent ->
                 send(parent, {:preflight_handoff, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:brief_lane, "Rework"}

    assert_receive {:preflight_handoff,
                    %SymphonyElixir.TransitionIntent{
                      id: "preflight-handoff:github:pr:authoritative-preflight-handoff:dispatch-123",
                      source: :orchestrator,
                      expected_state: "Reworking",
                      kind: :handoff_required,
                      head_oid: "head-123",
                      causation_id: "dispatch-123",
                      comment_body: body
                    }}

    assert body =~ "작업 에이전트를 시작하지 않고"
    assert body =~ ":github_preflight_unavailable"
    refute File.exists?(trace_file)
  end

  test "authoritative review uses the journal counter for the post-rework confirmation review" do
    test_root = test_root("authoritative-review-cycle")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    journal_path = Path.join(test_root, "transitions.log")

    outcome = %{
      "kind" => "review_findings",
      "summary_ko" => "추가 확인이 필요한 finding이 있습니다.",
      "evidence" => ["focused review"],
      "head_oid" => nil,
      "findings" => ["lib/example.ex"]
    }

    codex_binary = write_worker_outcome_codex!(test_root, trace_file, Jason.encode!(outcome))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      max_turns: 8,
      max_review_verdicts: 3,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Reworking", "Merging"]
    )

    enable_authoritative_mode!()

    journal =
      start_supervised!(
        {TransitionJournal, name: TransitionJournal, path: journal_path},
        restart: :temporary
      )

    issue = review_issue("authoritative-review-cycle")

    for {transition_id, kind} <-
          [{"dispatch-review-cycle", :dispatch_implementation}] ++
            Enum.map(1..3, &{"review-cycle-#{&1}", :review_findings}) do
      transition_data = %{issue_id: issue.id, kind: kind}

      assert {:ok, _} = TransitionJournal.record(journal, transition_id, :received, transition_data)
      assert {:ok, _} = TransitionJournal.record(journal, transition_id, :decided, transition_data)
      assert {:ok, _} = TransitionJournal.record(journal, transition_id, :verified, transition_data)
    end

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _brief_issue ->
                 {:ok, "live_head: unknown\nunresolved_feedback: none"}
               end,
               state_manager_requester: fn intent ->
                 send(parent, {:worker_outcome, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:worker_outcome,
                    %SymphonyElixir.TransitionIntent{
                      expected_state: "Review",
                      kind: :review_findings,
                      review_attempt: 4,
                      review_limit: 3
                    }}

    assert File.read!(trace_file) =~ "confirmation review after 3 automatic rework cycles"
  end

  test "three review findings complete three reworks before a fourth confirmation review reaches Human Review" do
    test_root = test_root("review-limit")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      max_turns: 7,
      max_review_verdicts: 3,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("limit")
    states = Agent.start_link(fn -> ["Rework", "Review", "Rework", "Review", "Rework", "Review", "Human Review"] end) |> elem(1)
    on_exit(fn -> if Process.alive?(states), do: Agent.stop(states) end)
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _issue ->
                 send(parent, :brief_generated)
                 {:ok, "lane: Review\nfocused_verification: direct test only"}
               end,
               issue_state_fetcher: fn [_issue_id] ->
                 next_state = Agent.get_and_update(states, fn [next | rest] -> {next, rest} end)
                 {:ok, [%{issue | state: next_state}]}
               end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:handoff_state, issue_id, state})
                 :ok
               end
             )

    assert_receive :brief_generated
    refute_receive :brief_generated
    refute_receive {:handoff_comment, "github:pr:limit", _body}
    refute_receive {:handoff_state, "github:pr:limit", "Human Review"}

    trace = File.read!(trace_file)
    assert count_lines(trace, "RUN:") == 7
    assert count_lines(trace, "THREAD:") == 7
    assert trace =~ "automatic rework cycle 1 of 3"
    assert trace =~ "automatic rework cycle 2 of 3"
    assert trace =~ "automatic rework cycle 3 of 3"
    assert trace =~ "confirmation review after 3 automatic rework cycles"
  end

  test "unexpected same active review state is handed to Human Review without retry" do
    test_root = test_root("contract")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("contract")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _issue -> {:ok, "lane: Review"} end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:handoff_state, issue_id, state})
                 :ok
               end
             )

    assert_receive {:handoff_comment, "github:pr:contract", body}
    assert body =~ "Review -> Review"
    assert_receive {:handoff_state, "github:pr:contract", "Human Review"}
    assert File.read!(trace_file) |> count_lines("RUN:") == 1
  end

  test "unexpected terminal review transition is handed to Human Review" do
    test_root = test_root("terminal-contract")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("terminal-contract")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _issue -> {:ok, "lane: Review"} end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:handoff_state, issue_id, state})
                 :ok
               end
             )

    assert_receive {:handoff_comment, "github:pr:terminal-contract", body}
    assert body =~ "Review -> Done"
    assert_receive {:handoff_state, "github:pr:terminal-contract", "Human Review"}
  end

  test "handoff comment failure prevents the Human Review state update" do
    test_root = test_root("comment-failure")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("comment-failure")
    parent = self()

    assert {:error, {:human_review_comment_failed, :comment_unavailable}} =
             AgentRunner.run(issue, nil,
               raise_on_error: false,
               brief_generator: fn _workspace, _issue -> {:ok, "lane: Review"} end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               tracker_commenter: fn _issue_id, _body -> {:error, :comment_unavailable} end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:unexpected_state_update, issue_id, state})
                 :ok
               end
             )

    refute_receive {:unexpected_state_update, _, _}
  end

  test "dispatch snapshot failure hands Rework to Human Review without starting a worker" do
    test_root = test_root("rework-fallback")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"],
      codex_task_profiles: %{
        single_file_edit: %{
          command: "#{codex_binary} --profile rework app-server",
          model: "gpt-5.6-terra",
          effort: "high"
        }
      }
    )

    issue = %{
      review_issue("rework-fallback")
      | state: "In Progress",
        labels: ["sym:rework"],
        metadata: %{"symphony_dispatch_state" => "Rework"}
    }

    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})
                 {:error, :preflight_unavailable}
               end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:snapshot_handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:snapshot_handoff_state, issue_id, state})
                 :ok
               end
             )

    assert_receive {:brief_lane, "Rework"}
    assert_receive {:snapshot_handoff_comment, "github:pr:rework-fallback", body}
    assert body =~ "broker_dispatch_snapshot_failed"
    assert_receive {:snapshot_handoff_state, "github:pr:rework-fallback", "Human Review"}
    refute File.exists?(trace_file)
  end

  test "worker metrics accept current camelCase token usage notifications" do
    test_root = test_root("worker-metrics")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    issue = review_issue("worker-metrics")

    assert :ok =
             AgentRunner.run(issue, self(),
               brief_generator: fn _workspace, _issue -> {:ok, "lane: Review"} end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Human Review"}]} end
             )

    assert_receive {:codex_worker_update, "github:pr:worker-metrics", %{event: :briefed_worker_metrics, payload: metrics}}

    assert metrics.input_tokens == 12
    assert metrics.cached_input_tokens == 7
    assert metrics.total_tokens == 16
  end

  test "authoritative worker repairs one malformed outcome in the same app-server session" do
    test_root = test_root("outcome-repair")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = Path.join(test_root, "fake-outcome-repair-codex")

    outcome =
      Jason.encode!(%{
        "kind" => "clean_review",
        "summary_ko" => "검토를 완료했습니다.",
        "evidence" => ["focused review passed"],
        "head_oid" => nil,
        "findings" => [],
        "review_thread_updates" => []
      })

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{trace_file}
    turn=0
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-repair"}}}'
          ;;
        *'"method":"turn/start"'*)
          turn=$((turn + 1))
          printf '{"id":3,"result":{"turn":{"id":"turn-repair-%s"}}}\\n' "$turn"
          if [ "$turn" -eq 1 ]; then
            printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-repair","turnId":"turn-repair-1","item":{"type":"agentMessage","text":"not-json"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-repair","turn":{"id":"turn-repair-1","items":[],"status":"completed"}}}'
          else
            printf '%s\\n' '#{Jason.encode!(%{"method" => "item/completed", "params" => %{"threadId" => "thread-repair", "turnId" => "turn-repair-2", "item" => %{"type" => "agentMessage", "text" => outcome}}})}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-repair","turn":{"id":"turn-repair-2","items":[],"status":"completed"}}}'
          fi
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    enable_authoritative_mode!()
    issue = review_issue("outcome-repair")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, self(),
               brief_generator: fn _workspace, _issue -> {:ok, "focused review"} end,
               state_manager_requester: fn intent ->
                 send(parent, {:repaired_outcome, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:repaired_outcome, %SymphonyElixir.TransitionIntent{kind: :clean_review}}

    assert_receive {:codex_worker_update, "github:pr:outcome-repair",
                    %{
                      event: :authoritative_worker_metrics,
                      payload: %{repair_attempted: true, outcome: :clean_review}
                    }}

    trace = File.read!(trace_file)
    assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    assert trace =~ "Do not call tools"
  end

  test "authoritative broker rejection completes the worker without another model attempt" do
    test_root = test_root("outcome-rejected")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")

    outcome =
      Jason.encode!(%{
        "kind" => "clean_review",
        "summary_ko" => "검토를 완료했습니다.",
        "evidence" => ["focused review passed"],
        "head_oid" => nil,
        "findings" => [],
        "review_thread_updates" => []
      })

    codex_binary = write_worker_outcome_codex!(test_root, trace_file, outcome)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    enable_authoritative_mode!()
    issue = review_issue("outcome-rejected")

    assert :ok =
             AgentRunner.run(issue, self(),
               brief_generator: fn _workspace, _issue -> {:ok, "focused review"} end,
               state_manager_requester: fn _intent -> {:rejected, :stale_head} end
             )

    assert_receive {:worker_transition_result, "github:pr:outcome-rejected", {:rejected, :stale_head}}

    assert_receive {:codex_worker_update, "github:pr:outcome-rejected",
                    %{
                      event: :authoritative_worker_metrics,
                      payload: %{
                        completion_class: :broker_handoff,
                        transition_result: "{:error, {:worker_outcome_rejected, :stale_head}}"
                      }
                    }}

    trace = File.read!(trace_file)
    assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
  end

  test "a second malformed authoritative outcome hands off without a fresh worker session" do
    test_root = test_root("outcome-repair-handoff")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = Path.join(test_root, "fake-outcome-repair-handoff-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{trace_file}
    turn=0
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-repair-handoff"}}}'
          ;;
        *'"method":"turn/start"'*)
          turn=$((turn + 1))
          printf '{"id":3,"result":{"turn":{"id":"turn-repair-handoff-%s"}}}\\n' "$turn"
          printf '{"method":"item/completed","params":{"threadId":"thread-repair-handoff","turnId":"turn-repair-handoff-%s","item":{"type":"agentMessage","text":"still-not-json"}}}\\n' "$turn"
          printf '{"method":"turn/completed","params":{"threadId":"thread-repair-handoff","turn":{"id":"turn-repair-handoff-%s","items":[],"status":"completed"}}}\\n' "$turn"
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    enable_authoritative_mode!()
    issue = review_issue("outcome-repair-handoff")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, self(),
               brief_generator: fn _workspace, _issue -> {:ok, "focused review"} end,
               state_manager_requester: fn intent ->
                 send(parent, {:repair_handoff, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:repair_handoff,
                    %SymphonyElixir.TransitionIntent{
                      kind: :handoff_required,
                      source: :orchestrator
                    } = intent}

    assert intent.comment_body =~ "같은 세션에서 한 번 교정"

    assert_receive {:worker_transition_result, "github:pr:outcome-repair-handoff", {:ok, %{}}}

    trace = File.read!(trace_file)
    assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
  end

  test "authoritative repair interrupts tool activity and hands off without a fresh model turn" do
    test_root = test_root("outcome-repair-tool-interrupt")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = Path.join(test_root, "fake-outcome-repair-tool-interrupt-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{trace_file}
    turn=0
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-repair-tool"}}}'
          ;;
        *'"method":"turn/start"'*)
          turn=$((turn + 1))
          printf '{"id":3,"result":{"turn":{"id":"turn-repair-tool-%s"}}}\\n' "$turn"
          if [ "$turn" -eq 1 ]; then
            printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-repair-tool","turnId":"turn-repair-tool-1","item":{"type":"agentMessage","text":"not-json"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-repair-tool","turn":{"id":"turn-repair-tool-1","items":[],"status":"completed"}}}'
          else
            printf '%s\\n' '{"method":"item/started","params":{"threadId":"thread-repair-tool","turnId":"turn-repair-tool-2","item":{"type":"commandExecution","command":"git status"}}}'
          fi
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"]
    )

    enable_authoritative_mode!()
    issue = review_issue("outcome-repair-tool-interrupt")
    parent = self()

    assert :ok =
             AgentRunner.run(issue, self(),
               brief_generator: fn _workspace, _issue -> {:ok, "focused review"} end,
               state_manager_requester: fn intent ->
                 send(parent, {:repair_tool_handoff, intent})
                 {:ok, %{}}
               end
             )

    assert_receive {:repair_tool_handoff, %SymphonyElixir.TransitionIntent{kind: :handoff_required}}

    trace = File.read!(trace_file)
    assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    assert trace =~ ~s("method":"turn/interrupt")

    repair_turn =
      trace
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
      |> Enum.filter(&(&1["method"] == "turn/start"))
      |> Enum.at(1)

    assert get_in(repair_turn, ["params", "sandboxPolicy"]) == %{
             "networkAccess" => false,
             "type" => "readOnly"
           }
  end

  test "Merging does not start a worker when the broker snapshot is unavailable" do
    test_root = test_root("merging")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "codex.trace")
    codex_binary = write_fake_codex!(test_root, trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      orchestration_brief_enabled: true,
      tracker_active_states: ["Review", "Reviewing", "Rework", "Merging"],
      verification_full_states: ["Merging"]
    )

    issue = %{review_issue("merging") | state: "Merging", labels: ["sym:merging"]}
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _issue -> {:error, :preflight_unavailable} end,
               tracker_commenter: fn issue_id, body ->
                 send(parent, {:snapshot_handoff_comment, issue_id, body})
                 :ok
               end,
               tracker_state_updater: fn issue_id, state ->
                 send(parent, {:snapshot_handoff_state, issue_id, state})
                 :ok
               end
             )

    assert_receive {:snapshot_handoff_comment, "github:pr:merging", body}
    assert body =~ "broker_dispatch_snapshot_failed"
    assert_receive {:snapshot_handoff_state, "github:pr:merging", "Human Review"}
    refute File.exists?(trace_file)
  end

  defp review_issue(suffix) do
    %Issue{
      id: "github:pr:#{suffix}",
      identifier: "PR ##{suffix}",
      title: "Review focused change",
      description: "Review the current pull request",
      state: "Review",
      kind: :pull_request,
      url: "https://example.test/pull/#{suffix}",
      labels: ["sym:review"]
    }
  end

  defp implementation_issue(suffix) do
    %Issue{
      id: "github:issue:#{suffix}",
      identifier: "Issue ##{suffix}",
      title: "Implement approved change",
      description: "Implement the approved issue scope",
      state: "Planned",
      kind: :issue,
      url: "https://example.test/issues/#{suffix}",
      labels: ["sym:planned"]
    }
  end

  defp test_root(suffix) do
    root = Path.join(System.tmp_dir!(), "symphony-briefed-agent-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp write_fake_codex!(test_root, trace_file) do
    codex_binary = Path.join(test_root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    printf 'RUN:%s\n' "$$" >> "$trace_file"
    printf 'ARGV:%s\n' "$*" >> "$trace_file"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf 'THREAD:%s\n' "$$" >> "$trace_file"
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-'"$$"'"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-'"$$"'"}}}'
          printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"inputTokens":12,"cachedInputTokens":7,"totalTokens":16}}}}'
          printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-'"$$"'","items":[],"status":"completed"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    codex_binary
  end

  defp write_worker_outcome_codex!(test_root, trace_file, outcome) do
    codex_binary = Path.join(test_root, "fake-worker-outcome-codex")

    notification =
      [
        Jason.encode!(%{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => outcome}}
        }),
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{
              "id" => "turn-worker",
              "items" => [],
              "status" => "completed"
            }
          }
        })
      ]
      |> Enum.join("\n")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    while IFS= read -r line; do
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-worker"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-worker"}}}'
          printf '%s\n' '#{notification}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    codex_binary
  end

  defp write_conflicting_worker_codex!(test_root, trace_file, publisher) do
    codex_binary = Path.join(test_root, "fake-conflicting-worker-codex")

    notification =
      [
        Jason.encode!(%{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" =>
                Jason.encode!(%{
                  "kind" => "implementation_complete",
                  "summary_ko" => "worker conflict",
                  "evidence" => [],
                  "head_oid" => "HEAD",
                  "findings" => []
                })
            }
          }
        }),
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"id" => "turn-worker", "items" => [], "status" => "completed"}
          }
        })
      ]
      |> Enum.join("\n")

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    publisher=#{inspect(publisher)}
    while IFS= read -r line; do
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-worker"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf 'worker\n' > README.md
          git add README.md >/dev/null 2>&1
          git commit -m 'worker conflict' >/dev/null 2>&1
          git -C "$publisher" checkout review-head >/dev/null 2>&1
          printf 'remote\n' > "$publisher/README.md"
          git -C "$publisher" commit -am 'remote conflict' >/dev/null 2>&1
          git -C "$publisher" push origin review-head >/dev/null 2>&1
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-worker"}}}'
          printf '%s\n' '#{notification}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    codex_binary
  end

  defp count_lines(text, prefix) do
    text
    |> String.split("\n", trim: true)
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  defp enable_authoritative_mode! do
    workflow_path = Workflow.workflow_file_path()

    updated =
      workflow_path
      |> File.read!()
      |> String.replace("polling:\n", "state_manager:\n  mode: authoritative\npolling:\n")

    File.write!(workflow_path, updated)
    :ok = WorkflowStore.force_reload()
  end
end
