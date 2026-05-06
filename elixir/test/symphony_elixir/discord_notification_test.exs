defmodule SymphonyElixir.DiscordNotificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notifications.Discord

  test "sends Discord webhook payload for configured notify state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      discord_notifications_enabled: true,
      discord_webhook_url: "https://discord.example/webhook",
      discord_notify_states: [nil, "Human Review"]
    )

    parent = self()

    request_fun = fn opts ->
      send(parent, {:discord_request, opts})
      {:ok, %Req.Response{status: 204, body: ""}}
    end

    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Review implementation",
      state: "Human Review",
      url: "https://tracker.example/MT-1",
      metadata: %{tracker: "linear"}
    }

    assert :ok = Discord.send_issue_state_transition(issue, "In Progress", "Human Review", request_fun: request_fun)

    assert_receive {:discord_request,
                    [
                      method: :post,
                      url: "https://discord.example/webhook",
                      json: %{content: content}
                    ]}

    assert content =~ "Symphony state changed"
    assert content =~ "MT-1: Review implementation"
    assert content =~ "In Progress -> Human Review"
    assert content =~ "tracker: linear"
    assert content =~ "https://tracker.example/MT-1"
  end

  test "matches notify states case-insensitively and handles unknown states with truncated content" do
    write_workflow_file!(Workflow.workflow_file_path(),
      discord_notifications_enabled: true,
      discord_webhook_url: "https://discord.example/webhook"
    )

    parent = self()

    request_fun = fn opts ->
      send(parent, {:discord_request, opts})
      {:ok, %Req.Response{status: 204, body: ""}}
    end

    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Review implementation",
      state: "Human Review"
    }

    assert Discord.notify_state?(" human review ")
    refute Discord.notify_state?(nil)

    assert :ok = Discord.send_issue_state_transition(issue, nil, "Human Review", request_fun: request_fun)

    assert_receive {:discord_request, [method: :post, url: "https://discord.example/webhook", json: %{content: content}]}

    assert content =~ "unknown -> Human Review"

    long_issue = %{issue | title: String.duplicate("Long title ", 220)}

    assert :ok =
             Discord.send_issue_state_transition(long_issue, "In Progress", "Human Review", request_fun: request_fun)

    assert_receive {:discord_request, [method: :post, url: "https://discord.example/webhook", json: %{content: content}]}

    assert String.ends_with?(content, "...")
  end

  test "returns error for unsuccessful Discord webhook response" do
    write_workflow_file!(Workflow.workflow_file_path(),
      discord_notifications_enabled: true,
      discord_webhook_url: "https://discord.example/webhook"
    )

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Done", state: "Done"}

    request_fun = fn _opts ->
      {:ok, %Req.Response{status: 500, body: "failed"}}
    end

    assert {:error, {:discord_webhook_status, 500, "failed"}} =
             Discord.send_issue_state_transition(issue, "In Progress", "Done", request_fun: request_fun)
  end

  test "returns error for Discord request failures and logs notification failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      discord_notifications_enabled: true,
      discord_webhook_url: "https://discord.example/webhook"
    )

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Done", state: "Done"}

    request_fun = fn _opts ->
      {:error, :econnrefused}
    end

    assert {:error, {:discord_webhook_request, :econnrefused}} =
             Discord.send_issue_state_transition(issue, "In Progress", "Done", request_fun: request_fun)

    assert capture_log(fn ->
             assert :ok = Discord.log_result({:error, :boom}, issue, "Done")
           end) =~ "Discord notification failed"
  end

  test "skips disabled Discord notifications without issuing a request" do
    write_workflow_file!(Workflow.workflow_file_path(), discord_notifications_enabled: false)

    request_fun = fn _opts ->
      flunk("request should not be sent when Discord notifications are disabled")
    end

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Done", state: "Done"}

    assert :ok = Discord.send_issue_state_transition(issue, "In Progress", "Done", request_fun: request_fun)
  end
end
