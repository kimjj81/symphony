defmodule SymphonyElixir.CmuxNotificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notifications.Cmux

  test "sends cmux notify command for configured notify state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      cmux_notifications_enabled: true,
      cmux_command: "/usr/local/bin/cmux"
    )

    parent = self()

    command_fun = fn command, args, opts ->
      send(parent, {:cmux_notify, command, args, opts})
      {"OK", 0}
    end

    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Review implementation",
      state: "Human Review",
      url: "https://tracker.example/MT-1",
      metadata: %{tracker: "linear"}
    }

    assert :ok = Cmux.send_issue_state_transition(issue, "In Progress", "Human Review", command_fun: command_fun)

    assert_receive {:cmux_notify, "/usr/local/bin/cmux", args, [stderr_to_stdout: true]}

    assert args == [
             "notify",
             "--title",
             "Symphony MT-1",
             "--subtitle",
             "In Progress -> Human Review",
             "--body",
             "Review implementation\ntracker: linear\nhttps://tracker.example/MT-1"
           ]
  end

  test "returns error for unsuccessful cmux command" do
    write_workflow_file!(Workflow.workflow_file_path(), cmux_notifications_enabled: true)

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Done", state: "Done"}

    command_fun = fn _command, _args, _opts ->
      {"socket unavailable\n", 1}
    end

    assert {:error, {:cmux_notify_status, 1, "socket unavailable"}} =
             Cmux.send_issue_state_transition(issue, "In Progress", "Done", command_fun: command_fun)
  end

  test "skips disabled cmux notifications without issuing a command" do
    write_workflow_file!(Workflow.workflow_file_path(), cmux_notifications_enabled: false)

    command_fun = fn _command, _args, _opts ->
      flunk("command should not run when cmux notifications are disabled")
    end

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Done", state: "Done"}

    assert :ok = Cmux.send_issue_state_transition(issue, "In Progress", "Done", command_fun: command_fun)
  end
end
