defmodule SymphonyElixir.BriefedAgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.OrchestrationBrief

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

    oversized_map = Map.put(brief, :lane, String.duplicate("x", 8_193))

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
      "lane" => "Review",
      "unresolved_feedback" => [],
      "allowed_scope" => ["agent runner"],
      "focused_verification" => ["mix test focused"],
      "stop_conditions" => ["head drift"],
      "transitions" => ["clean -> Human Review"]
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
      "lane" => "Review",
      "unresolved_feedback" => [],
      "allowed_scope" => ["legacy app-server"],
      "focused_verification" => ["mix test focused"],
      "stop_conditions" => ["head drift"],
      "transitions" => ["clean -> Human Review"]
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

    assert fallback =~ "lane: unknown"
    assert fallback =~ "inspect only the current live tracker feedback"
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
    refute trace =~ "You are an agent for this repository."
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
    assert trace =~ "lane: Rework"
    assert trace =~ "State: Rework"
    assert trace =~ "unresolved live PR review threads and comments once"
    assert trace =~ "Rework completion moves to Review"
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
    assert trace =~ "wait for required CI checks"
    assert trace =~ "lane: Merging"
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

  defp count_lines(text, prefix) do
    text
    |> String.split("\n", trim: true)
    |> Enum.count(&String.starts_with?(&1, prefix))
  end
end
