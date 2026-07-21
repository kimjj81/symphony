defmodule SymphonyElixir.GitHubWebhookProcessorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.WebhookProcessor

  test "ingests pull request review comments without mutating tracker state" do
    test_pid = self()

    payload = %{
      "action" => "created",
      "pull_request" => %{"number" => 259},
      "sender" => %{"login" => "reviewer"}
    }

    result =
      WebhookProcessor.handle_event("pull_request_review_comment", payload,
        tracker_kind: "github",
        intent_fun: fn intent ->
          send(test_pid, {:intent, intent})
          :ok
        end,
        refresh_fun: fn issue_id ->
          send(test_pid, {:refresh, issue_id})
          {:ok, %{queued: true, issue_id: issue_id}}
        end
      )

    assert {:ok, %{queued: true, issue_id: "github:pr:259", event: "pull_request_review_comment", action: "created"}} = result

    assert_receive {:intent,
                    %{
                      kind: :review_feedback_detected,
                      issue_id: "github:pr:259",
                      source: :github_webhook,
                      actor: "reviewer"
                    }}

    assert_receive {:refresh, "github:pr:259"}
  end

  test "normalizes request labels as operator transition intents" do
    payload = %{
      "action" => "labeled",
      "issue" => %{"number" => 42},
      "label" => %{"name" => "sym:request-merging"},
      "sender" => %{"login" => "maintainer", "type" => "User"}
    }

    assert {:ok, intent} = WebhookProcessor.normalize_intent("issues", "labeled", payload)
    assert intent.kind == :operator_transition_requested
    assert intent.issue_id == "github:issue:42"
    assert intent.requested_state == "Merging"
    assert intent.request_action == "labeled"
    assert intent.actor == "maintainer"
  end

  test "distinguishes Symphony projection echoes from human state-label drift" do
    base = %{
      "action" => "labeled",
      "pull_request" => %{"number" => 91},
      "label" => %{"name" => "sym:reworking"}
    }

    assert {:ok, %{kind: :projection_echo, observed_state: "Reworking"}} =
             WebhookProcessor.normalize_intent(
               "pull_request",
               "labeled",
               Map.put(base, "sender", %{"login" => "symphony[bot]", "type" => "Bot"})
             )

    assert {:ok, %{kind: :state_projection_drift, observed_state: "Reworking"}} =
             WebhookProcessor.normalize_intent(
               "pull_request",
               "labeled",
               Map.put(base, "sender", %{"login" => "maintainer", "type" => "User"})
             )

    assert {:ok, %{kind: :state_projection_drift, observed_state: nil}} =
             WebhookProcessor.normalize_intent(
               "pull_request",
               "unlabeled",
               Map.put(base, "sender", %{"login" => "maintainer", "type" => "User"})
             )
  end

  test "continues targeted refresh after state-less drift is accepted as a no-effect receipt" do
    test_pid = self()

    payload = %{
      "action" => "labeled",
      "pull_request" => %{"number" => 549},
      "label" => %{"name" => "sym:waiting"},
      "sender" => %{"login" => "maintainer", "type" => "User"}
    }

    assert {:ok, %{issue_id: "github:pr:549"}} =
             WebhookProcessor.handle_event("pull_request", payload,
               tracker_kind: "github",
               intent_fun: fn intent ->
                 send(test_pid, {:intent, intent})
                 {:noop, :canonical_state_unavailable}
               end,
               refresh_fun: fn issue_id ->
                 send(test_pid, {:refresh, issue_id})
                 {:ok, %{issue_id: issue_id}}
               end
             )

    assert_receive {:intent, %{kind: :state_projection_drift, issue_id: "github:pr:549"}}
    assert_receive {:refresh, "github:pr:549"}
  end

  test "retries targeted refresh when a verified delivery is redelivered" do
    test_pid = self()

    payload = %{
      "action" => "labeled",
      "pull_request" => %{"number" => 549},
      "label" => %{"name" => "sym:waiting"},
      "sender" => %{"login" => "maintainer", "type" => "User"}
    }

    intent_fun = fn intent ->
      send(test_pid, {:intent, intent})
      {:noop, :already_applied}
    end

    refresh_fun = fn issue_id ->
      count = Process.get(:github_refresh_count, 0)
      Process.put(:github_refresh_count, count + 1)
      send(test_pid, {:refresh, issue_id})
      if count == 0, do: {:error, :unavailable}, else: {:ok, %{issue_id: issue_id}}
    end

    opts = [tracker_kind: "github", intent_fun: intent_fun, refresh_fun: refresh_fun]

    assert {:error, :unavailable} =
             WebhookProcessor.handle_event("pull_request", payload, opts)

    assert_receive {:refresh, "github:pr:549"}

    assert {:ok, %{issue_id: "github:pr:549"}} =
             WebhookProcessor.handle_event("pull_request", payload, opts)

    assert_receive {:refresh, "github:pr:549"}
  end

  test "ignores unrelated actions without refreshing" do
    test_pid = self()
    payload = %{"action" => "opened", "pull_request" => %{"number" => 259}}

    result =
      WebhookProcessor.handle_event("pull_request", payload,
        tracker_kind: "github",
        intent_fun: fn intent -> send(test_pid, {:intent, intent}) end,
        refresh_fun: fn issue_id ->
          send(test_pid, {:refresh, issue_id})
          {:ok, %{issue_id: issue_id}}
        end
      )

    assert {:ignored, %{event: "pull_request", action: "opened"}} = result
    refute_receive {:intent, _}, 50
    refute_receive {:refresh, _}, 50
  end
end
