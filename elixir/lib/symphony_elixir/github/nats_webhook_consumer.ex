defmodule SymphonyElixir.GitHub.NatsWebhookConsumer do
  @moduledoc """
  JetStream consumer that feeds GitHub webhook relay messages into Symphony.

  The Oracle relay publishes signed GitHub deliveries as JSON envelopes to the
  `GITHUB_WEBHOOKS` stream. This consumer uses its own durable consumer to
  process the event stream independently from other consumers.
  """

  use Gnat.Jetstream.PullConsumer

  require Logger

  alias Gnat.ConnectionSupervisor
  alias Gnat.Jetstream.API.Consumer
  alias Gnat.Jetstream.PullConsumer
  alias SymphonyElixir.GitHub.WebhookProcessor
  alias SymphonyElixir.Orchestrator

  @default_stream "GITHUB_WEBHOOKS"
  @default_durable "symphony-webhook"
  @default_subject "github.webhook.*"
  @default_connection_name SymphonyElixir.GitHub.NatsConnection

  @type config :: %{
          enabled: boolean(),
          nats_url: String.t(),
          stream: String.t(),
          durable: String.t(),
          subject: String.t(),
          connection_name: GenServer.name()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    PullConsumer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    stream = Keyword.fetch!(opts, :stream)
    durable = Keyword.fetch!(opts, :durable)
    subject = Keyword.fetch!(opts, :subject)

    consumer = %Consumer{
      stream_name: stream,
      durable_name: durable,
      filter_subject: subject,
      ack_policy: :explicit,
      inactive_threshold: Keyword.get(opts, :inactive_threshold, 2_592_000_000_000_000)
    }

    Logger.info("starting Symphony GitHub NATS webhook consumer stream=#{stream} durable=#{durable} subject=#{subject}")

    {:ok, opts, connection_name: Keyword.fetch!(opts, :connection_name), consumer: consumer, batch_size: Keyword.get(opts, :batch_size, 1)}
  end

  @impl true
  def handle_message(%{body: body}, state) do
    case Jason.decode(IO.iodata_to_binary(body)) do
      {:ok, envelope} ->
        handle_decoded_envelope(envelope, state)

      {:error, reason} ->
        Logger.warning("Symphony GitHub NATS webhook JSON decode failed reason=#{inspect(reason)}")
        {:term, state}
    end
  end

  defp handle_decoded_envelope(envelope, state) do
    case handle_envelope(envelope, state) do
      :ok ->
        {:ack, state}

      {:error, :invalid_envelope = reason} ->
        Logger.warning("Symphony GitHub NATS webhook envelope rejected reason=#{inspect(reason)}")
        {:term, state}

      {:error, reason} ->
        Logger.warning("Symphony GitHub NATS webhook envelope rejected reason=#{inspect(reason)}")
        {:nack, state}
    end
  end

  @spec handle_envelope(map(), keyword()) :: :ok | {:error, term()}
  def handle_envelope(%{"event" => event, "payload" => payload} = envelope, opts)
      when is_binary(event) and is_map(payload) do
    delivery_id = Map.get(envelope, "delivery_id", "")
    processor_fun = Keyword.get(opts, :processor_fun, &WebhookProcessor.handle_event/3)

    processor_opts =
      opts
      |> Keyword.put(:delivery_id, delivery_id)
      |> Keyword.put_new(:intent_fun, fn intent ->
        intent
        |> Map.put(:delivery_id, delivery_id)
        |> Orchestrator.request_tracker_intent(Keyword.get(opts, :orchestrator, Orchestrator))
      end)

    case invoke_processor(processor_fun, event, payload, processor_opts) do
      {:ok, payload} ->
        Logger.info("Symphony GitHub NATS webhook processed event=#{event} delivery=#{delivery_id} result=refresh issue_id=#{inspect(Map.get(payload, :issue_id))}")
        :ok

      {:ignored, payload} ->
        Logger.debug("Symphony GitHub NATS webhook ignored event=#{event} delivery=#{delivery_id} action=#{inspect(Map.get(payload, :action))}")
        :ok

      {:error, reason} ->
        Logger.warning("Symphony GitHub NATS webhook processing failed event=#{event} delivery=#{delivery_id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle_envelope(_envelope, _opts), do: {:error, :invalid_envelope}

  @spec config_from_env(map()) :: config()
  def config_from_env(env \\ System.get_env()) when is_map(env) do
    %{
      enabled: truthy?(Map.get(env, "SYMPHONY_NATS_WEBHOOK_ENABLED")),
      nats_url: Map.get(env, "SYMPHONY_NATS_URL", "nats://127.0.0.1:4222"),
      stream: Map.get(env, "SYMPHONY_NATS_STREAM", @default_stream),
      durable: Map.get(env, "SYMPHONY_NATS_DURABLE", @default_durable),
      subject: Map.get(env, "SYMPHONY_NATS_SUBJECT", @default_subject),
      connection_name: @default_connection_name
    }
  end

  @spec connection_settings(String.t()) :: Gnat.connection_settings()
  def connection_settings(nats_url) when is_binary(nats_url) do
    uri = URI.parse(nats_url)

    %{
      host: uri.host || "127.0.0.1",
      port: uri.port || 4222,
      tls: uri.scheme == "tls"
    }
  end

  @spec child_specs_from_env(map()) :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs_from_env(env \\ System.get_env()) when is_map(env) do
    config = config_from_env(env)

    if config.enabled do
      connection_settings = [connection_settings(config.nats_url)]

      [
        {ConnectionSupervisor, %{name: config.connection_name, connection_settings: connection_settings}},
        {__MODULE__, connection_name: config.connection_name, stream: config.stream, durable: config.durable, subject: config.subject}
      ]
    else
      []
    end
  end

  defp invoke_processor(processor_fun, event, payload, _opts) when is_function(processor_fun, 2) do
    processor_fun.(event, payload)
  end

  defp invoke_processor(processor_fun, event, payload, opts) when is_function(processor_fun, 3) do
    processor_opts =
      Keyword.take(opts, [
        :orchestrator,
        :follow_up_delay_ms,
        :tracker_kind,
        :sync_fun,
        :queue_rework_fun,
        :refresh_fun,
        :intent_fun,
        :delivery_id
      ])

    processor_fun.(event, payload, processor_opts)
  end

  defp truthy?(value) when is_binary(value), do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  defp truthy?(true), do: true
  defp truthy?(_value), do: false
end
