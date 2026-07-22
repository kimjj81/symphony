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
      unresolved_feedback: ["thread-1", "thread-2"],
      allowed_scope: ["agent runner"],
      focused_verification: ["mix test focused"],
      stop_conditions: ["head drift"],
      transitions: ["clean -> Human Review"]
    }

    assert {:ok, rendered, %{source: :agent, lane: "Review", bytes: bytes}} =
             OrchestrationBrief.normalize_for_test({:ok, brief}, issue)

    assert byte_size(rendered) == bytes
    assert rendered =~ "live_head: unknown"
    assert rendered =~ "thread-1 | thread-2"
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

  test "orchestration preflight uses a read-only Codex session and decodes its result" do
    test_root = test_root("preflight-success")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "preflight")
    trace_file = Path.join(test_root, "preflight.trace")
    File.mkdir_p!(workspace)

    brief = %{
      "live_head" => "abc123",
      "unresolved_feedback" => [],
      "focused_verification" => ["mix test focused"],
      "stop_conditions" => ["head drift"]
    }

    codex_binary = write_preflight_codex!(test_root, trace_file, {:completed, Jason.encode!(brief)})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue = review_issue("preflight-success")

    assert {:ok, rendered, %{source: :agent, lane: "Review"}} =
             OrchestrationBrief.generate(workspace, issue)

    assert rendered =~ "live_head: abc123"
    refute rendered =~ "lane:"
    trace = File.read!(trace_file)
    assert trace =~ "outputSchema"
    assert trace =~ "thread/start"
  end

  test "orchestration preflight still decodes a legacy embedded agent message" do
    test_root = test_root("preflight-legacy-success")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "preflight")
    trace_file = Path.join(test_root, "preflight.trace")
    File.mkdir_p!(workspace)

    brief = %{
      "live_head" => "legacy123",
      "unresolved_feedback" => [],
      "focused_verification" => ["mix test focused"],
      "stop_conditions" => ["head drift"]
    }

    codex_binary =
      write_preflight_codex!(test_root, trace_file, {:completed_legacy, Jason.encode!(brief)})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:ok, rendered, %{source: :agent, lane: "Review"}} =
             OrchestrationBrief.generate(workspace, review_issue("preflight-legacy-success"))

    assert rendered =~ "live_head: legacy123"
  end

  test "orchestration preflight returns Codex turn failures" do
    test_root = test_root("preflight-failure")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "preflight")
    trace_file = Path.join(test_root, "preflight.trace")
    File.mkdir_p!(workspace)
    codex_binary = write_preflight_codex!(test_root, trace_file, {:failed, "preflight failed"})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:turn_failed, %{"error" => "preflight failed"}}} =
             OrchestrationBrief.generate(workspace, review_issue("preflight-failure"))
  end

  test "fallback handles an unknown lane deterministically" do
    issue = %{review_issue("unknown-lane") | state: nil}
    fallback = OrchestrationBrief.fallback(issue)

    assert fallback =~ "live_head: use the tracker head metadata"
    assert fallback =~ "tracker feedback already present in the workflow context"
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
      orchestration_brief_enabled: true
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
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})
                 {:ok, "live_head: unknown\nunresolved_feedback: none"}
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
                      kind: :implementation_complete,
                      work_item_kind: :issue,
                      causation_id: "dispatch-issue-529"
                    }}

    trace = File.read!(trace_file)
    assert trace =~ "Execution mode: implementation"
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
    assert trace =~ "review verdict 1 of 3"
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

  test "three review findings stop in Human Review without a fourth verdict" do
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
    states = Agent.start_link(fn -> ["Rework", "Review", "Rework", "Review", "Rework"] end) |> elem(1)
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
    assert_receive {:handoff_comment, "github:pr:limit", body}
    assert body =~ "자동 리뷰 판정 한도(3회)"
    assert_receive {:handoff_state, "github:pr:limit", "Human Review"}

    trace = File.read!(trace_file)
    assert count_lines(trace, "RUN:") == 5
    assert count_lines(trace, "THREAD:") == 5
    assert trace =~ "review verdict 1 of 3"
    assert trace =~ "review verdict 2 of 3"
    assert trace =~ "review verdict 3 of 3"
    refute trace =~ "review verdict 4 of 3"
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

  test "dispatch metadata restores Rework for fallback, profile selection, and transition" do
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

    states = Agent.start_link(fn -> ["Review", "Human Review"] end) |> elem(1)
    on_exit(fn -> if Process.alive?(states), do: Agent.stop(states) end)
    parent = self()

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, brief_issue ->
                 send(parent, {:brief_lane, brief_issue.state})
                 {:error, :preflight_unavailable}
               end,
               issue_state_fetcher: fn [_issue_id] ->
                 next_state = Agent.get_and_update(states, fn [next | rest] -> {next, rest} end)
                 {:ok, [%{issue | state: next_state, metadata: %{}}]}
               end
             )

    assert_receive {:brief_lane, "Rework"}
    trace = File.read!(trace_file)
    assert trace =~ "Execution mode: rework"
    assert trace =~ "State: Rework"
    assert trace =~ "tracker feedback already present in the workflow context"
    assert trace =~ "return the matching semantic outcome"
    assert trace =~ "Symphony decides and applies the tracker transition"
    assert trace =~ "ARGV:--profile rework app-server"
    assert count_lines(trace, "RUN:") == 2
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

  test "Merging uses full verification while a failed brief uses the compact fallback" do
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

    assert :ok =
             AgentRunner.run(issue, nil,
               brief_generator: fn _workspace, _issue -> {:error, :preflight_unavailable} end,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    trace = File.read!(trace_file)
    assert trace =~ "Verification tier: full"
    assert trace =~ "full local verification bundle"
    assert trace =~ "Symphony validates required CI"
    assert trace =~ "Execution mode: merge"
    assert count_lines(trace, "RUN:") == 1
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

  defp write_preflight_codex!(test_root, trace_file, outcome) do
    codex_binary = Path.join(test_root, "fake-preflight-codex")

    notification =
      case outcome do
        {:completed, text} ->
          [
            Jason.encode!(%{
              "method" => "item/completed",
              "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
            }),
            Jason.encode!(%{
              "method" => "turn/completed",
              "params" => %{
                "turn" => %{
                  "id" => "turn-preflight",
                  "items" => [],
                  "status" => "completed"
                }
              }
            })
          ]
          |> Enum.join("\n")

        {:completed_legacy, text} ->
          Jason.encode!(%{
            "method" => "turn/completed",
            "params" => %{
              "turn" => %{
                "id" => "turn-preflight",
                "items" => [%{"type" => "agentMessage", "text" => text}],
                "status" => "completed"
              }
            }
          })

        {:failed, reason} ->
          Jason.encode!(%{"method" => "turn/failed", "params" => %{"error" => reason}})
      end

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-preflight"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-preflight"}}}'
          printf '%s\n' '#{notification}'
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
