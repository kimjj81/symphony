defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @github_webhook_events ~w(issues pull_request pull_request_review issue_comment)
  @github_webhook_actions ~w(labeled unlabeled closed reopened synchronize submitted created)
  @github_webhook_secret_env "SYMPHONY_GITHUB_WEBHOOK_SECRET"
  @github_webhook_follow_up_refresh_ms 2_000

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
      action = params |> Map.get("action") |> to_string()

      if github_webhook_refresh_event?(event, action) do
        github_webhook_refresh_response(conn, event, action)
      else
        conn
        |> put_status(202)
        |> json(%{ignored: true, event: event, action: action})
      end
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "github_webhook_secret_missing", "GitHub webhook secret is not configured")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "GitHub webhook signature is invalid")
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

  defp github_webhook_refresh_response(conn, event, action) do
    case Presenter.webhook_refresh_payload(orchestrator(), github_webhook_follow_up_refresh_ms()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(Map.merge(payload, %{event: event, action: action}))

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
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

  defp verify_github_signature(conn, secret) do
    signature = header_value(conn, "x-hub-signature-256")
    expected_signature = "sha256=" <> hmac_sha256(raw_body(conn), secret)

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

  defp github_webhook_refresh_event?(event, action) do
    event in @github_webhook_events and action in @github_webhook_actions
  end
end
