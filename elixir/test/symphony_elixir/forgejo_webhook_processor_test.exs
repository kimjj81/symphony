defmodule SymphonyElixir.ForgejoWebhookProcessorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Forgejo.WebhookProcessor

  test "ingests pull request review comments and targets provider-qualified refreshes" do
    test_pid = self()

    payload = %{
      "action" => "created",
      "pull_request" => %{"number" => 259},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"},
      "sender" => %{"login" => "reviewer"}
    }

    result =
      WebhookProcessor.handle_event("pull_request_review_comment", payload,
        tracker_kind: "forgejo",
        repository: "acme/widgets",
        endpoint_origin: "https://forgejo.example/api/v1",
        intent_fun: fn intent ->
          send(test_pid, {:intent, intent})
          :ok
        end,
        refresh_fun: fn issue_id ->
          send(test_pid, {:refresh, issue_id})
          {:ok, %{queued: true, issue_id: issue_id}}
        end
      )

    assert {:ok,
            %{
              queued: true,
              issue_id: "forgejo:pr:259",
              event: "pull_request_review_comment",
              action: "created"
            }} = result

    assert_receive {:intent,
                    %{
                      kind: :review_feedback_detected,
                      issue_id: "forgejo:pr:259",
                      source: :forgejo_webhook,
                      actor: "reviewer"
                    }}

    assert_receive {:refresh, "forgejo:pr:259"}
  end

  test "normalizes request labels as Forgejo operator transition intents" do
    payload = %{
      "action" => "labeled",
      "issue" => %{"number" => 42},
      "label" => %{"name" => "sym:request-merging"},
      "sender" => %{"login" => "maintainer"}
    }

    assert {:ok, intent} = WebhookProcessor.normalize_intent("issues", "labeled", payload)
    assert intent.kind == :operator_transition_requested
    assert intent.issue_id == "forgejo:issue:42"
    assert intent.source == :forgejo_webhook
    assert intent.requested_state == "Merging"
    assert intent.request_action == "labeled"
    assert intent.actor == "maintainer"
  end

  test "normalizes Forgejo v16 label_updated payloads from the top-level label and label deltas" do
    payload = %{
      "action" => "label_updated",
      "pull_request" => %{"number" => 42},
      "label" => %{"name" => "sym:request-rework"},
      "changes" => %{
        "labels" => %{
          "removed" => [%{"name" => "sym:planned"}]
        }
      },
      "sender" => %{"login" => "maintainer"}
    }

    assert [
             %{action: "labeled", kind: :operator_transition_requested, label: "sym:request-rework"},
             %{action: "unlabeled", kind: :state_projection_drift, label: "sym:planned", observed_state: nil}
           ] = WebhookProcessor.normalize_intents("pull_request", "label_updated", payload)
  end

  test "uses stable per-intent delivery ids for native multi-label Forgejo deliveries" do
    test_pid = self()

    payload = %{
      "action" => "label_updated",
      "issue" => %{"number" => 42},
      "changes" => %{
        "labels" => %{
          "added" => [%{"name" => "sym:request-rework"}],
          "removed" => [%{"name" => "sym:planned"}]
        }
      },
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"},
      "sender" => %{"login" => "maintainer"}
    }

    assert {:ok, %{issue_id: "forgejo:issue:42", action: "label_updated"}} =
             WebhookProcessor.handle_event("issues", payload,
               tracker_kind: "forgejo",
               repository: "acme/widgets",
               endpoint_origin: "https://forgejo.example/api/v1",
               delivery_id: "forgejo-delivery-42",
               intent_fun: fn intent ->
                 send(test_pid, {:intent, intent})
                 :ok
               end,
               refresh_fun: fn issue_id ->
                 send(test_pid, {:refresh, issue_id})
                 {:ok, %{issue_id: issue_id}}
               end
             )

    assert_receive {:intent, %{delivery_id: "forgejo-delivery-42:1", kind: :operator_transition_requested}}
    assert_receive {:intent, %{delivery_id: "forgejo-delivery-42:2", kind: :state_projection_drift}}
    assert_receive {:refresh, "forgejo:issue:42"}
  end

  test "does not refresh again when the journal reports a duplicate Forgejo delivery" do
    test_pid = self()

    payload = %{
      "action" => "labeled",
      "issue" => %{"number" => 42},
      "label" => %{"name" => "sym:request-rework"},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
    }

    intent_fun = fn intent ->
      count = Process.get(:forgejo_delivery_count, 0)
      Process.put(:forgejo_delivery_count, count + 1)
      send(test_pid, {:intent, intent})
      if count == 0, do: :ok, else: {:noop, :already_applied}
    end

    refresh_fun = fn issue_id ->
      send(test_pid, {:refresh, issue_id})
      {:ok, %{issue_id: issue_id}}
    end

    opts = [
      tracker_kind: "forgejo",
      repository: "acme/widgets",
      endpoint_origin: "https://forgejo.example/api/v1",
      delivery_id: "forgejo-delivery-42",
      intent_fun: intent_fun,
      refresh_fun: refresh_fun
    ]

    assert {:ok, %{issue_id: "forgejo:issue:42"}} = WebhookProcessor.handle_event("issues", payload, opts)
    assert_receive {:refresh, "forgejo:issue:42"}

    assert {:ignored, %{reason: :duplicate_delivery}} = WebhookProcessor.handle_event("issues", payload, opts)
    refute_receive {:refresh, "forgejo:issue:42"}, 50
  end

  test "fails closed before ingesting conflicting operator request labels in one native delivery" do
    test_pid = self()

    payload = %{
      "action" => "label_updated",
      "issue" => %{"number" => 42},
      "changes" => %{
        "labels" => %{
          "added" => [%{"name" => "sym:request-rework"}, %{"name" => "sym:request-merging"}]
        }
      },
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
    }

    assert {:ignored, %{reason: :conflicting_label_changes}} =
             WebhookProcessor.handle_event("issues", payload,
               tracker_kind: "forgejo",
               repository: "acme/widgets",
               endpoint_origin: "https://forgejo.example/api/v1",
               intent_fun: fn intent -> send(test_pid, {:intent, intent}) end,
               refresh_fun: fn issue_id -> send(test_pid, {:refresh, issue_id}) end
             )

    refute_receive {:intent, _}, 50
    refute_receive {:refresh, _}, 50
  end

  test "normalizes reopened Forgejo items for the StateManager reopen transition" do
    payload = %{
      "action" => "reopened",
      "issue" => %{"number" => 42},
      "sender" => %{"login" => "maintainer"}
    }

    assert {:ok, intent} = WebhookProcessor.normalize_intent("issues", "reopened", payload)
    assert intent.kind == :item_reopened
    assert intent.issue_id == "forgejo:issue:42"
  end

  test "recognizes pull requests embedded in Forgejo issue payloads" do
    payload = %{
      "issue" => %{
        "number" => "91",
        "pull_request" => %{"url" => "https://forgejo.example/api/v1/repos/acme/repo/pulls/91"}
      }
    }

    assert WebhookProcessor.issue_id("issues", payload) == "forgejo:pr:91"
    assert WebhookProcessor.issue_id("issue_comment", payload) == "forgejo:pr:91"
  end

  test "ignores unrelated actions without ingesting or refreshing" do
    test_pid = self()

    payload = %{
      "action" => "opened",
      "pull_request" => %{"number" => 259},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
    }

    result =
      WebhookProcessor.handle_event("pull_request", payload,
        tracker_kind: "forgejo",
        repository: "acme/widgets",
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

  test "accepts refresh-only intents and refreshes the provider-qualified pull request" do
    test_pid = self()

    payload = %{
      "action" => "synchronize",
      "pull_request" => %{"number" => 259, "head" => %{"sha" => "new-head"}},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
    }

    assert {:ok, %{issue_id: "forgejo:pr:259", action: "synchronize"}} =
             WebhookProcessor.handle_event("pull_request", payload,
               tracker_kind: "forgejo",
               repository: "acme/widgets",
               endpoint_origin: "https://forgejo.example/api/v1",
               intent_fun: fn intent ->
                 send(test_pid, {:intent, intent})
                 {:noop, :head_updated}
               end,
               refresh_fun: fn issue_id ->
                 send(test_pid, {:refresh, issue_id})
                 {:ok, %{issue_id: issue_id}}
               end
             )

    assert_receive {:intent, %{kind: :head_updated, head_oid: "new-head"}}
    assert_receive {:refresh, "forgejo:pr:259"}
  end

  test "ignores a valid delivery for another repository before intent ingestion" do
    payload = %{
      "action" => "reopened",
      "issue" => %{"number" => 259},
      "repository" => %{"full_name" => "other/widgets", "html_url" => "https://forgejo.example/other/widgets"}
    }

    assert {:ignored, %{reason: :repository_mismatch}} =
             WebhookProcessor.handle_event("issues", payload,
               tracker_kind: "forgejo",
               repository: "acme/widgets",
               endpoint_origin: "https://forgejo.example/api/v1",
               intent_fun: fn _ -> flunk("must not ingest") end,
               refresh_fun: fn _ -> flunk("must not refresh") end
             )
  end

  test "ignores matching repository names from another Forgejo instance" do
    payload = %{
      "action" => "synchronize",
      "pull_request" => %{"number" => 259, "head" => %{"sha" => "new-head"}},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://other-forgejo.example/acme/widgets"}
    }

    assert {:ignored, %{reason: :instance_mismatch}} =
             WebhookProcessor.handle_event("pull_request", payload,
               tracker_kind: "forgejo",
               repository: "acme/widgets",
               endpoint_origin: "https://forgejo.example/api/v1",
               intent_fun: fn _ -> flunk("must not ingest") end,
               refresh_fun: fn _ -> flunk("must not refresh") end
             )
  end

  test "ignores Forgejo delivery when Forgejo is not the active tracker" do
    payload = %{
      "action" => "synchronize",
      "pull_request" => %{"number" => 259, "head" => %{"sha" => "new-head"}},
      "repository" => %{"full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
    }

    assert {:ignored, %{reason: :inactive_tracker}} =
             WebhookProcessor.handle_event("pull_request", payload,
               tracker_kind: "github",
               intent_fun: fn _ -> flunk("must not ingest") end,
               refresh_fun: fn _ -> flunk("must not refresh") end
             )
  end
end
