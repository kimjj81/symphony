defmodule SymphonyElixir.GitHubWebhookProcessorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.WebhookProcessor

  test "processes pull request review comments as targeted PR refreshes" do
    test_pid = self()

    payload = %{
      "action" => "created",
      "pull_request" => %{"number" => 259}
    }

    result =
      WebhookProcessor.handle_event("pull_request_review_comment", payload,
        tracker_kind: "github",
        sync_fun: fn event, action, received_payload ->
          send(test_pid, {:sync, event, action, received_payload})
          :ok
        end,
        queue_rework_fun: fn event, action, received_payload ->
          send(test_pid, {:queue_rework, event, action, received_payload})
          :ok
        end,
        refresh_fun: fn issue_id ->
          send(test_pid, {:refresh, issue_id})
          {:ok, %{queued: true, issue_id: issue_id}}
        end
      )

    assert {:ok, %{queued: true, issue_id: "github:pr:259", event: "pull_request_review_comment", action: "created"}} = result
    assert_receive {:sync, "pull_request_review_comment", "created", ^payload}
    assert_receive {:queue_rework, "pull_request_review_comment", "created", ^payload}
    assert_receive {:refresh, "github:pr:259"}
  end

  test "ignores unrelated actions after state sync" do
    test_pid = self()
    payload = %{"action" => "opened", "pull_request" => %{"number" => 259}}

    result =
      WebhookProcessor.handle_event("pull_request", payload,
        tracker_kind: "github",
        sync_fun: fn event, action, _payload ->
          send(test_pid, {:sync, event, action})
          :ok
        end,
        refresh_fun: fn issue_id ->
          send(test_pid, {:refresh, issue_id})
          {:ok, %{issue_id: issue_id}}
        end
      )

    assert {:ignored, %{event: "pull_request", action: "opened"}} = result
    assert_receive {:sync, "pull_request", "opened"}
    refute_receive {:refresh, _}, 50
  end
end
