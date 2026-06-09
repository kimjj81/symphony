defmodule SymphonyElixir.GitHubNatsWebhookConsumerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.NatsWebhookConsumer

  test "handles relay envelopes with event and payload" do
    test_pid = self()

    envelope = %{
      "event" => "pull_request_review_comment",
      "delivery_id" => "delivery-1",
      "payload" => %{"action" => "created", "pull_request" => %{"number" => 259}}
    }

    assert :ok =
             NatsWebhookConsumer.handle_envelope(envelope,
               processor_fun: fn event, payload ->
                 send(test_pid, {:processed, event, payload})
                 {:ok, %{event: event}}
               end
             )

    assert_receive {:processed, "pull_request_review_comment", %{"action" => "created"}}
  end

  test "rejects malformed envelopes" do
    assert {:error, :invalid_envelope} = NatsWebhookConsumer.handle_envelope(%{"payload" => %{}}, [])
    assert {:error, :invalid_envelope} = NatsWebhookConsumer.handle_envelope(%{"event" => "issues"}, [])
  end

  test "builds disabled config by default" do
    assert %{enabled: false} = NatsWebhookConsumer.config_from_env(%{})
  end

  test "builds enabled config from environment" do
    assert %{
             enabled: true,
             nats_url: "nats://100.77.171.83:24222",
             stream: "GITHUB_WEBHOOKS",
             durable: "symphony-webhook",
             subject: "github.webhook.*"
           } =
             NatsWebhookConsumer.config_from_env(%{
               "SYMPHONY_NATS_WEBHOOK_ENABLED" => "true",
               "SYMPHONY_NATS_URL" => "nats://100.77.171.83:24222"
             })
  end
end
