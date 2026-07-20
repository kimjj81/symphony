defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Forgejo.WebhookProcessor, as: ForgejoWebhookProcessor
  alias SymphonyElixir.GitHub.WebhookProcessor, as: GitHubWebhookProcessor
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @github_webhook_secret_env "SYMPHONY_GITHUB_WEBHOOK_SECRET"
  @github_webhook_follow_up_refresh_ms 2_000
  @forgejo_webhook_secret_env "SYMPHONY_FORGEJO_WEBHOOK_SECRET"
  @forgejo_webhook_follow_up_refresh_ms 2_000
  @forgejo_event_header_max_bytes 64
  @forgejo_delivery_header_max_bytes 128
  @forgejo_signature_bytes 64

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec github_webhook(Conn.t(), map()) :: Conn.t()
  def github_webhook(conn, params) do
    with {:ok, secret} <- github_webhook_secret(),
         :ok <- verify_github_signature(conn, secret) do
      event = conn |> header_value("x-github-event") |> to_string()
      delivery_id = conn |> header_value("x-github-delivery") |> to_string()
      orchestrator = orchestrator()

      case GitHubWebhookProcessor.handle_event(event, params,
             orchestrator: orchestrator,
             intent_fun: fn intent ->
               intent
               |> Map.put(:delivery_id, delivery_id)
               |> Orchestrator.request_tracker_intent(orchestrator)
             end,
             follow_up_delay_ms: github_webhook_follow_up_refresh_ms()
           ) do
        {:ok, payload} ->
          conn
          |> put_status(202)
          |> json(payload)

        {:ignored, payload} ->
          conn
          |> put_status(202)
          |> json(Map.put(payload, :ignored, true))

        {:error, :unavailable} ->
          error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
      end
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "github_webhook_secret_missing", "GitHub webhook secret is not configured")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "GitHub webhook signature is invalid")
    end
  end

  @spec forgejo_webhook(Conn.t(), map()) :: Conn.t()
  def forgejo_webhook(conn, params) do
    with {:ok, secret} <- forgejo_webhook_secret(),
         {:ok, event} <- required_forgejo_header(conn, "x-forgejo-event", @forgejo_event_header_max_bytes),
         {:ok, delivery_id} <- required_forgejo_header(conn, "x-forgejo-delivery", @forgejo_delivery_header_max_bytes),
         {:ok, signature} <- forgejo_signature_header(conn),
         :ok <- verify_forgejo_signature(conn, secret, signature) do
      orchestrator = orchestrator()

      case ForgejoWebhookProcessor.handle_event(event, params,
             orchestrator: orchestrator,
             delivery_id: delivery_id,
             intent_fun: &Orchestrator.request_tracker_intent(&1, orchestrator),
             follow_up_delay_ms: forgejo_webhook_follow_up_refresh_ms()
           ) do
        {:ok, payload} ->
          conn
          |> put_status(202)
          |> json(payload)

        {:ignored, payload} ->
          conn
          |> put_status(202)
          |> json(Map.put(payload, :ignored, true))

        {:error, :unavailable} ->
          error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
      end
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "forgejo_webhook_secret_missing", "Forgejo webhook secret is not configured")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "Forgejo webhook signature is invalid")

      {:error, {:invalid_forgejo_header, _header}} ->
        error_response(conn, 400, "invalid_webhook_headers", "Forgejo webhook event and delivery headers are required exactly once")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp github_webhook_follow_up_refresh_ms do
    Endpoint.config(:github_webhook_follow_up_refresh_ms) || @github_webhook_follow_up_refresh_ms
  end

  defp forgejo_webhook_follow_up_refresh_ms do
    Endpoint.config(:forgejo_webhook_follow_up_refresh_ms) || @forgejo_webhook_follow_up_refresh_ms
  end

  defp github_webhook_secret do
    secret =
      Endpoint.config(:github_webhook_secret) ||
        System.get_env(@github_webhook_secret_env)

    case secret do
      secret when is_binary(secret) ->
        secret = String.trim(secret)
        if secret == "", do: {:error, :missing_secret}, else: {:ok, secret}

      _ ->
        {:error, :missing_secret}
    end
  end

  defp forgejo_webhook_secret do
    secret =
      Endpoint.config(:forgejo_webhook_secret) ||
        System.get_env(@forgejo_webhook_secret_env)

    case secret do
      secret when is_binary(secret) ->
        secret = String.trim(secret)
        if secret == "", do: {:error, :missing_secret}, else: {:ok, secret}

      _ ->
        {:error, :missing_secret}
    end
  end

  defp verify_github_signature(conn, secret) do
    signature = header_value(conn, "x-hub-signature-256")
    expected_signature = "sha256=" <> hmac_sha256(raw_body(conn), secret)

    if secure_compare(signature, expected_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_forgejo_signature(conn, secret, signature) do
    expected_signature = hmac_sha256(raw_body(conn), secret)

    if secure_compare(signature, expected_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp raw_body(conn) do
    conn.private
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp hmac_sha256(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp header_value(conn, header) do
    conn
    |> get_req_header(header)
    |> List.first()
  end

  defp required_forgejo_header(conn, header, max_bytes) do
    case get_req_header(conn, header) do
      [value] when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= max_bytes,
          do: {:ok, value},
          else: {:error, {:invalid_forgejo_header, header}}

      _ ->
        {:error, {:invalid_forgejo_header, header}}
    end
  end

  defp forgejo_signature_header(conn) do
    with {:ok, signature} <- required_forgejo_header(conn, "x-forgejo-signature", @forgejo_signature_bytes),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, signature) do
      {:ok, signature}
    else
      _ -> {:error, :invalid_signature}
    end
  end
end
