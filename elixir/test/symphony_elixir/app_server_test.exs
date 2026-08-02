defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "extracts final agent messages from completed turn and item payloads" do
    payload = %{
      "params" => %{
        "turn" => %{
          "items" => [
            %{"type" => "agentMessage", "text" => "first"},
            %{"type" => "commandExecution", "command" => "true"},
            %{"type" => "agentMessage", "text" => "final"}
          ]
        }
      }
    }

    assert AppServer.final_agent_message(payload) == "final"

    assert AppServer.final_agent_message(%{
             "method" => "item/completed",
             "params" => %{"item" => %{"type" => "agentMessage", "text" => "streamed"}}
           }) == "streamed"

    assert AppServer.final_agent_message(%{}) == nil
  end

  test "local worker receives verified orchestration evidence and cleanup removes it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-evidence-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-EVIDENCE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "evidence.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      evidence_path="${SYMPHONY_ORCHESTRATION_EVIDENCE-}"
      printf 'PATH=%s\n' "$evidence_path" > #{inspect(trace_file)}
      printf 'MODE=%s\n' "$(stat -f '%Lp' "$evidence_path" 2>/dev/null || stat -c '%a' "$evidence_path")" >> #{inspect(trace_file)}
      printf 'CONTENT=' >> #{inspect(trace_file)}
      tr '\n' '|' < "$evidence_path" >> #{inspect(trace_file)}
      printf '\n' >> #{inspect(trace_file)}
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-evidence"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-evidence"}}}'
            printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-evidence","items":[],"status":"completed"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-evidence",
        identifier: "MT-EVIDENCE",
        title: "Read orchestration evidence",
        state: "In Progress",
        labels: []
      }

      content = "schema_version: 1\nwork_item:\n  title: \"Evidence\"\n"

      evidence = %{
        filename: "orchestration-evidence.yaml",
        content: content,
        bytes: byte_size(content),
        sha256: sha256(content)
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Inspect evidence", issue, orchestration_evidence: evidence)

      trace = File.read!(trace_file)
      [path_line | _rest] = String.split(trace, "\n", trim: true)
      evidence_path = String.replace_prefix(path_line, "PATH=", "")

      assert trace =~ "MODE=400"
      assert trace =~ "CONTENT=schema_version: 1|work_item:|  title: \"Evidence\"|"
      refute File.exists?(evidence_path)
    after
      File.rm_rf(test_root)
    end
  end

  test "local evidence validation and startup failures clean the worker runtime" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-evidence-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-EVIDENCE-FAILURE")
      codex_binary = Path.join(test_root, "failing-codex")
      File.mkdir_p!(workspace)
      File.write!(codex_binary, "#!/bin/sh\nexit 1\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      before_runtime_dirs = worker_runtime_dirs()
      content = "schema_version: 1\n"

      invalid_cases = [
        {:invalid_shape, {:orchestration_evidence_write_failed, :invalid_orchestration_evidence}},
        {%{
           filename: "orchestration-evidence.yaml",
           content: content,
           bytes: byte_size(content) + 1,
           sha256: sha256(content)
         }, {:orchestration_evidence_write_failed, :orchestration_evidence_size_mismatch}},
        {%{
           filename: "orchestration-evidence.yaml",
           content: content,
           bytes: byte_size(content),
           sha256: String.duplicate("0", 64)
         }, {:orchestration_evidence_write_failed, :orchestration_evidence_digest_mismatch}}
      ]

      Enum.each(invalid_cases, fn {evidence, expected_error} ->
        assert {:error, ^expected_error} =
                 AppServer.start_session(workspace, orchestration_evidence: evidence)

        assert worker_runtime_dirs() == before_runtime_dirs
      end)

      oversized = String.duplicate("x", 8 * 1024 * 1024 + 1)

      assert {:error, {:orchestration_evidence_write_failed, {:orchestration_evidence_too_large, 8_388_609}}} =
               AppServer.start_session(workspace,
                 orchestration_evidence: %{
                   filename: "orchestration-evidence.yaml",
                   content: oversized,
                   bytes: byte_size(oversized),
                   sha256: sha256(oversized)
                 }
               )

      assert worker_runtime_dirs() == before_runtime_dirs

      assert {:error, _reason} =
               AppServer.start_session(workspace,
                 orchestration_evidence: %{
                   filename: "orchestration-evidence.yaml",
                   content: content,
                   bytes: byte_size(content),
                   sha256: sha256(content)
                 }
               )

      assert worker_runtime_dirs() == before_runtime_dirs
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn returns the last streamed agent message when completed turn items are empty" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-streamed-agent-message-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STREAM")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-stream"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-stream"}}}'
            printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"first"}}}'
            printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"final"}}}'
            printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-stream","items":[],"status":"completed"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-streamed-agent-message",
        identifier: "MT-STREAM",
        title: "Capture streamed agent message",
        description: "Exercise current app-server completion events",
        state: "In Progress",
        url: "https://example.org/issues/MT-STREAM",
        labels: ["backend"]
      }

      assert {:ok,
              %{
                final_agent_message: "final",
                result: %{"method" => "turn/completed"}
              }} = AppServer.run(workspace, "Return the final message", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn ignores foreign child-turn messages and completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-root-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ROOT-TURN")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-root"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-root"}}}'
            printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-child","turnId":"turn-child","item":{"type":"agentMessage","text":"markdown child review"}}}'
            printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-child","turn":{"id":"turn-child","items":[{"type":"agentMessage","text":"child final"}],"status":"completed"}}}'
            printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-root","turnId":"turn-root","item":{"type":"agentMessage","text":"root structured outcome"}}}'
            printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"completed"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-root-turn",
        identifier: "MT-ROOT-TURN",
        title: "Keep the root outcome",
        state: "In Progress"
      }

      assert {:ok,
              %{
                final_agent_message: "root structured outcome",
                result: %{"params" => %{"turn" => %{"id" => "turn-root"}}}
              }} = AppServer.run(workspace, "Return the root outcome", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn rejects failed interrupted and unknown completed-turn statuses" do
    Enum.each(
      [
        {"failed", :turn_failed},
        {"interrupted", :turn_cancelled},
        {"future", :turn_failed}
      ],
      fn {status, expected_event} ->
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-app-server-turn-status-#{status}-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          workspace = Path.join(workspace_root, "MT-STATUS")
          codex_binary = Path.join(test_root, "fake-codex")
          File.mkdir_p!(workspace)

          File.write!(codex_binary, """
          #!/bin/sh
          while IFS= read -r line; do
            case "$line" in
              *'"method":"initialize"'*)
                printf '%s\n' '{"id":1,"result":{}}'
                ;;
              *'"method":"thread/start"'*)
                printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-status"}}}'
                ;;
              *'"method":"turn/start"'*)
                printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-status"}}}'
                printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-status","items":[],"status":"#{status}"}}}'
                ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            codex_command: "#{codex_binary} app-server"
          )

          issue = %Issue{
            id: "issue-turn-status-#{status}",
            identifier: "MT-STATUS",
            title: "Reject #{status} completion",
            state: "In Progress",
            labels: []
          }

          assert {:error, reason} =
                   AppServer.run(workspace, "Exercise #{status} completion", issue, on_message: fn message -> send(self(), {:app_server_message, message}) end)

          params = %{"turn" => %{"id" => "turn-status", "items" => [], "status" => status}}

          expected_reason =
            case status do
              "failed" -> {:turn_failed, params}
              "interrupted" -> {:turn_cancelled, params}
              "future" -> {:unexpected_turn_status, "future", params}
            end

          assert reason == expected_reason
          assert_receive {:app_server_message, %{event: ^expected_event}}, 1_000
          assert_receive {:app_server_message, %{event: :turn_ended_with_error}}, 1_000
          refute_received {:app_server_message, %{event: :turn_completed}}
        after
          File.rm_rf(test_root)
        end
      end
    )
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{
          "type" => "workspaceWrite",
          "writableRoots" => ["relative/path"],
          "networkAccess" => true
        },
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server includes selected model and effort in turn start payload" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-profile-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1002")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-turn-profile.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-turn-profile.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1002"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1002"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-turn-profile",
        identifier: "MT-1002",
        title: "Validate turn profile",
        description: "Ensure runtime forwards selected model and effort",
        state: "In Progress",
        url: "https://example.org/issues/MT-1002",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Validate selected turn profile", issue,
                 model: "gpt-5.6-terra",
                 effort: "high"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "model"]) == "gpt-5.6-terra" &&
                     get_in(payload, ["params", "effort"]) == "high"
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   get_in(payload, ["params", "dynamicTools"]) == []
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and
                   get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, [
                     "result",
                     "answers",
                     "mcp_tool_call_approval_call-717",
                     "answers"
                   ]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112 and
                   get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                     "This is a non-interactive session. Operator input is unavailable."
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue,
                 worker_tool_policy: :legacy_read_only,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   Enum.any?(
                     get_in(payload, ["params", "dynamicTools"]) || [],
                     &(&1["name"] == "linear_graphql")
                   )
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message,
                       %{
                         event: :tool_call_failed,
                         payload: %{"params" => %{"tool" => "linear_graphql"}}
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}

      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    previous_custom_write_token = System.get_env("CUSTOM_FORGEJO_WRITE_TOKEN")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      restore_env("CUSTOM_FORGEJO_WRITE_TOKEN", previous_custom_write_token)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      fake_scp = Path.join(test_root, "scp")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
      System.put_env("CUSTOM_FORGEJO_WRITE_TOKEN", "forgejo-custom-broker-write")

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *fake-remote-codex*)
          ;;
        *)
          exit 0
          ;;
      esac

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      File.write!(fake_scp, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'SCP_ARGV:%s\\n' "$*" >> "$trace_file"
      exit 0
      """)

      File.chmod!(fake_scp, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server",
        tracker_kind: "forgejo",
        tracker_endpoint: "https://forgejo.example/api/v1",
        tracker_owner: "acme",
        tracker_repo: "widgets",
        tracker_read_api_token: "forgejo-read-only",
        tracker_write_api_token: "$CUSTOM_FORGEJO_WRITE_TOKEN"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      evidence_content = "schema_version: 1\nwork_item:\n  title: \"Remote evidence\"\n"

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200",
                 orchestration_evidence: %{
                   filename: "orchestration-evidence.yaml",
                   content: evidence_content,
                   bytes: byte_size(evidence_content),
                   sha256: sha256(evidence_content)
                 }
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &(String.starts_with?(&1, "ARGV:") and &1 =~ "fake-remote-codex"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "mkdir -p"
      assert argv_line =~ "symphony-worker-gh-config-"
      assert argv_line =~ "trap "
      assert argv_line =~ "XDG_CACHE_HOME="
      assert argv_line =~ "/cache/xdg"
      assert argv_line =~ "UV_CACHE_DIR="
      assert argv_line =~ "/cache/uv"
      assert argv_line =~ "MYVEN_GITLEAKS_CACHE_DIR="
      assert argv_line =~ "/cache/gitleaks"
      assert argv_line =~ "SYMPHONY_ORCHESTRATION_EVIDENCE="
      assert argv_line =~ "/orchestration-evidence.yaml"
      assert argv_line =~ "-u ASANA_PAT"
      assert argv_line =~ "-u GITHUB_TOKEN"
      assert argv_line =~ "-u GH_TOKEN"
      assert argv_line =~ "-u GITLAB_PAT"
      assert argv_line =~ "-u GITLAB_ACCESS_TOKEN"
      assert argv_line =~ "-u JIRA_API_TOKEN"
      assert argv_line =~ "-u FORGEJO_TOKEN"
      assert argv_line =~ "-u SYMPHONY_TRACKER_READ_TOKEN"
      assert argv_line =~ "-u SYMPHONY_TRACKER_WRITE_TOKEN"
      assert argv_line =~ "-u LINEAR_API_KEY"
      assert argv_line =~ "-u CUSTOM_FORGEJO_WRITE_TOKEN"
      assert argv_line =~ "-u SYMPHONY_FORGEJO_WEBHOOK_SECRET"
      assert argv_line =~ "-u SYMPHONY_GITHUB_WEBHOOK_SECRET"
      refute argv_line =~ "FORGEJO_TOKEN="
      refute argv_line =~ "SYMPHONY_TRACKER_READ_TOKEN="
      refute argv_line =~ "forgejo-read-only"
      refute argv_line =~ "forgejo-custom-broker-write"
      assert argv_line =~ "fake-remote-codex app-server"

      assert scp_line = Enum.find(lines, &String.starts_with?(&1, "SCP_ARGV:"))
      assert scp_line =~ "-P 2200"
      assert scp_line =~ "worker-01:/tmp/symphony-worker-gh-config-"
      assert scp_line =~ "/orchestration-evidence.yaml"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "remote evidence copy and verification failures clean staging and remote runtime paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-evidence-failure-#{System.unique_integer([:positive])}"
      )

    trace_file = Path.join(test_root, "remote.trace")
    fake_ssh = Path.join(test_root, "ssh")
    fake_scp = Path.join(test_root, "scp")
    previous_path = System.get_env("PATH")
    previous_scp_status = System.get_env("SYMP_TEST_SCP_STATUS")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SCP_STATUS", previous_scp_status)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'SSH:%s\n' "$*" >> #{inspect(trace_file)}
    case "$*" in
      *"rm -rf --"*) exit 0 ;;
      *"wc -c <"*) exit 1 ;;
      *) exit 0 ;;
    esac
    """)

    File.write!(fake_scp, """
    #!/bin/sh
    printf 'SCP:%s\n' "$*" >> #{inspect(trace_file)}
    exit "${SYMP_TEST_SCP_STATUS:-0}"
    """)

    File.chmod!(fake_ssh, 0o755)
    File.chmod!(fake_scp, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    content = "schema_version: 1\n"

    evidence = %{
      filename: "orchestration-evidence.yaml",
      content: content,
      bytes: byte_size(content),
      sha256: sha256(content)
    }

    assert {:error, {:orchestration_evidence_upload_failed, {:remote_evidence_verification_failed, 1, _output}}} =
             AppServer.start_session("/remote/workspaces/MT-REMOTE-FAILURE",
               worker_host: "worker-01",
               codex_command: "fake-codex app-server",
               orchestration_evidence: evidence
             )

    verification_trace = File.read!(trace_file)
    assert verification_trace =~ "wc -c <"
    assert verification_trace =~ "rm -rf --"
    assert staging_path = scp_staging_path(verification_trace)
    refute File.exists?(staging_path)
    refute verification_trace =~ "fake-codex app-server"

    File.write!(trace_file, "")
    System.put_env("SYMP_TEST_SCP_STATUS", "9")

    assert {:error, {:orchestration_evidence_upload_failed, {:remote_evidence_copy_failed, 9, _output}}} =
             AppServer.start_session("/remote/workspaces/MT-REMOTE-COPY-FAILURE",
               worker_host: "worker-01",
               codex_command: "fake-codex app-server",
               orchestration_evidence: evidence
             )

    copy_trace = File.read!(trace_file)
    assert copy_trace =~ "SCP:"
    assert copy_trace =~ "rm -rf --"
    assert staging_path = scp_staging_path(copy_trace)
    refute File.exists?(staging_path)
    refute copy_trace =~ "wc -c <"
    refute copy_trace =~ "fake-codex app-server"
  end

  test "local workers receive no tracker credentials" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-local-credentials-#{System.unique_integer([:positive])}"
      )

    credential_envs = [
      "GH_TOKEN",
      "GITHUB_TOKEN",
      "FORGEJO_TOKEN",
      "SYMPHONY_TRACKER_READ_TOKEN",
      "SYMPHONY_TRACKER_WRITE_TOKEN",
      "SYMPHONY_FORGEJO_WEBHOOK_SECRET",
      "SYMPHONY_GITHUB_WEBHOOK_SECRET",
      "CUSTOM_FORGEJO_READ_TOKEN",
      "CUSTOM_FORGEJO_WRITE_TOKEN",
      "SYMP_TEST_LOCAL_ENV_TRACE"
    ]

    previous_env = Map.new(credential_envs, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-LOCAL-CREDENTIALS")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "worker.env")

      File.mkdir_p!(workspace)

      System.put_env("GH_TOKEN", "github-parent-token")
      System.put_env("GITHUB_TOKEN", "github-legacy-token")
      System.put_env("FORGEJO_TOKEN", "forgejo-legacy-write-token")
      System.put_env("SYMPHONY_TRACKER_READ_TOKEN", "forgejo-read-only-token")
      System.put_env("SYMPHONY_TRACKER_WRITE_TOKEN", "tracker-write-token")
      System.put_env("SYMPHONY_FORGEJO_WEBHOOK_SECRET", "forgejo-webhook-secret")
      System.put_env("SYMPHONY_GITHUB_WEBHOOK_SECRET", "github-webhook-secret")
      System.put_env("CUSTOM_FORGEJO_READ_TOKEN", "custom-read-token")
      System.put_env("CUSTOM_FORGEJO_WRITE_TOKEN", "custom-write-token")
      System.put_env("SYMP_TEST_LOCAL_ENV_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      {
        printf 'GH_TOKEN=%s\\n' "${GH_TOKEN-unset}"
        printf 'GITHUB_TOKEN=%s\\n' "${GITHUB_TOKEN-unset}"
        printf 'FORGEJO_TOKEN=%s\\n' "${FORGEJO_TOKEN-unset}"
        printf 'SYMPHONY_TRACKER_READ_TOKEN=%s\\n' "${SYMPHONY_TRACKER_READ_TOKEN-unset}"
        printf 'SYMPHONY_TRACKER_WRITE_TOKEN=%s\\n' "${SYMPHONY_TRACKER_WRITE_TOKEN-unset}"
        printf 'SYMPHONY_FORGEJO_WEBHOOK_SECRET=%s\\n' "${SYMPHONY_FORGEJO_WEBHOOK_SECRET-unset}"
        printf 'SYMPHONY_GITHUB_WEBHOOK_SECRET=%s\\n' "${SYMPHONY_GITHUB_WEBHOOK_SECRET-unset}"
        printf 'CUSTOM_FORGEJO_READ_TOKEN=%s\\n' "${CUSTOM_FORGEJO_READ_TOKEN-unset}"
        printf 'CUSTOM_FORGEJO_WRITE_TOKEN=%s\\n' "${CUSTOM_FORGEJO_WRITE_TOKEN-unset}"
        printf 'XDG_CACHE_HOME=%s\\n' "${XDG_CACHE_HOME-unset}"
        printf 'UV_CACHE_DIR=%s\\n' "${UV_CACHE_DIR-unset}"
        printf 'MYVEN_GITLEAKS_CACHE_DIR=%s\\n' "${MYVEN_GITLEAKS_CACHE_DIR-unset}"
      } > "$SYMP_TEST_LOCAL_ENV_TRACE"

      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-credentials"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-credentials"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        tracker_kind: "forgejo",
        tracker_endpoint: "https://forgejo.example/api/v1",
        tracker_owner: "acme",
        tracker_repo: "widgets",
        tracker_read_api_token: "$CUSTOM_FORGEJO_READ_TOKEN",
        tracker_write_api_token: "$CUSTOM_FORGEJO_WRITE_TOKEN"
      )

      issue = %Issue{
        id: "issue-local-credentials",
        identifier: "MT-LOCAL-CREDENTIALS",
        title: "Fence worker credentials",
        state: "In Progress",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Inspect worker credentials", issue)

      worker_env =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [name, value] = String.split(line, "=", parts: 2)
          {name, value}
        end)

      assert worker_env["GH_TOKEN"] == "unset"
      assert worker_env["GITHUB_TOKEN"] == "unset"
      assert worker_env["FORGEJO_TOKEN"] == "unset"
      assert worker_env["SYMPHONY_TRACKER_READ_TOKEN"] == "unset"
      assert worker_env["SYMPHONY_TRACKER_WRITE_TOKEN"] == "unset"
      assert worker_env["SYMPHONY_FORGEJO_WEBHOOK_SECRET"] == "unset"
      assert worker_env["SYMPHONY_GITHUB_WEBHOOK_SECRET"] == "unset"
      assert worker_env["CUSTOM_FORGEJO_READ_TOKEN"] == "unset"
      assert worker_env["CUSTOM_FORGEJO_WRITE_TOKEN"] == "unset"

      xdg_cache = worker_env["XDG_CACHE_HOME"]
      uv_cache = worker_env["UV_CACHE_DIR"]
      gitleaks_cache = worker_env["MYVEN_GITLEAKS_CACHE_DIR"]
      cache_root = Path.dirname(xdg_cache)
      worker_runtime_dir = Path.dirname(cache_root)

      assert Path.basename(xdg_cache) == "xdg"
      assert Path.dirname(uv_cache) == cache_root
      assert Path.basename(uv_cache) == "uv"
      assert Path.dirname(gitleaks_cache) == cache_root
      assert Path.basename(gitleaks_cache) == "gitleaks"
      assert Path.basename(worker_runtime_dir) =~ "symphony-worker-gh-config-"
      refute File.exists?(worker_runtime_dir)
    after
      File.rm_rf(test_root)
    end
  end

  test "standalone daemon clears all tracker credentials before launching Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-daemon-credentials-#{System.unique_integer([:positive])}"
      )

    try do
      state_dir = Path.join(test_root, "state")
      env_file = Path.join(test_root, "appserver.env")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(state_dir, "daemon.env")
      port = 40_000 + rem(System.unique_integer([:positive]), 10_000)

      File.mkdir_p!(state_dir)
      File.touch!(env_file)

      File.write!(codex_binary, """
      #!/bin/sh
      {
        printf 'FORGEJO_TOKEN=%s\\n' "${FORGEJO_TOKEN-unset}"
        printf 'SYMPHONY_TRACKER_READ_TOKEN=%s\\n' "${SYMPHONY_TRACKER_READ_TOKEN-unset}"
        printf 'SYMPHONY_TRACKER_WRITE_TOKEN=%s\\n' "${SYMPHONY_TRACKER_WRITE_TOKEN-unset}"
        printf 'CUSTOM_DAEMON_WRITE_TOKEN=%s\\n' "${CUSTOM_DAEMON_WRITE_TOKEN-unset}"
        printf 'SYMPHONY_FORGEJO_WEBHOOK_SECRET=%s\\n' "${SYMPHONY_FORGEJO_WEBHOOK_SECRET-unset}"
        printf 'HTTPS_PROXY=%s\\n' "${HTTPS_PROXY-unset}"
      } > "$(dirname "$GH_CONFIG_DIR")/daemon.env"
      sleep 2
      """)

      File.chmod!(codex_binary, 0o755)

      {output, 0} =
        System.cmd("bash", [Path.expand("../../scripts/codex-appserver-daemon.sh", __DIR__)],
          env: [
            {"CODEX_APPSERVER_ENV", env_file},
            {"CODEX_APPSERVER_STATE_DIR", state_dir},
            {"CODEX_APPSERVER_START_TIMEOUT_SEC", "0"},
            {"CODEX_WS_PORT", Integer.to_string(port)},
            {"CODEX_BIN", codex_binary},
            {"SYMPHONY_TRACKER_KIND", "forgejo"},
            {"SYMPHONY_TRACKER_READ_TOKEN", "forgejo-read-only-token"},
            {"SYMPHONY_TRACKER_WRITE_TOKEN", "tracker-write-token"},
            {"CUSTOM_DAEMON_WRITE_TOKEN", "custom-write-token"},
            {"SYMPHONY_FORGEJO_WEBHOOK_SECRET", "forgejo-webhook-secret"},
            {"HTTPS_PROXY", "https://proxy.example"}
          ],
          stderr_to_stdout: true
        )

      assert output =~ "INFO: booting codex app-server"

      assert await_file!(trace_file) == """
             FORGEJO_TOKEN=unset
             SYMPHONY_TRACKER_READ_TOKEN=unset
             SYMPHONY_TRACKER_WRITE_TOKEN=unset
             CUSTOM_DAEMON_WRITE_TOKEN=unset
             SYMPHONY_FORGEJO_WEBHOOK_SECRET=unset
             HTTPS_PROXY=https://proxy.example
             """
    after
      File.rm_rf(test_root)
    end
  end

  defp await_file!(path) do
    Enum.reduce_while(1..40, nil, fn _attempt, _contents ->
      path
      |> File.read()
      |> await_file_result()
    end)
  end

  defp await_file_result({:ok, contents}) do
    if String.contains?(contents, "HTTPS_PROXY=") do
      {:halt, contents}
    else
      retry_file_read()
    end
  end

  defp await_file_result(_result), do: retry_file_read()

  defp retry_file_read do
    Process.sleep(25)
    {:cont, nil}
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp worker_runtime_dirs do
    System.tmp_dir!()
    |> Path.join("symphony-worker-gh-config-*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp scp_staging_path(trace) do
    case Regex.run(~r/SCP:.*-- (\S+) \S+/, trace, capture: :all_but_first) do
      [path] -> path
      _ -> flunk("missing scp staging path in trace: #{trace}")
    end
  end
end
