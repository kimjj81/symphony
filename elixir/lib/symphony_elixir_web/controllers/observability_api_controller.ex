defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
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
      issue_id = github_webhook_issue_id(event, params)

      sync_github_webhook_state(event, action, params, issue_id)

      if github_webhook_refresh_event?(event, action) do
        github_webhook_refresh_response(conn, event, action, issue_id)
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

  defp github_webhook_refresh_response(conn, event, action, issue_id) do
    case Presenter.webhook_refresh_payload(orchestrator(), github_webhook_follow_up_refresh_ms(), issue_id) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(Map.merge(payload, github_webhook_response_metadata(event, action, issue_id)))

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  defp github_webhook_response_metadata(event, action, issue_id) when is_binary(issue_id) do
    %{event: event, action: action, issue_id: issue_id}
  end

  defp github_webhook_response_metadata(event, action, _issue_id), do: %{event: event, action: action}

  defp sync_github_webhook_state(event, action, params, issue_id) do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "github"}}} ->
        do_sync_github_webhook_state(event, action, params, issue_id)

      _ ->
        :ok
    end
  end

  defp do_sync_github_webhook_state(event, action, params, issue_id) do
    case GitHubAdapter.sync_webhook_state(event, action, params) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("GitHub webhook state sync failed event=#{event} action=#{action} issue_id=#{inspect(issue_id)} reason=#{inspect(reason)}")
        :ok
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

  defp github_webhook_issue_id("pull_request", %{"pull_request" => %{"number" => number}}) do
    github_issue_id(:pull_request, number)
  end

  defp github_webhook_issue_id("pull_request", %{"number" => number}) do
    github_issue_id(:pull_request, number)
  end

  defp github_webhook_issue_id("pull_request_review", %{"pull_request" => %{"number" => number}}) do
    github_issue_id(:pull_request, number)
  end

  defp github_webhook_issue_id("issue_comment", %{"issue" => issue}) when is_map(issue) do
    github_issue_id(github_issue_kind(issue), Map.get(issue, "number"))
  end

  defp github_webhook_issue_id("issues", %{"issue" => issue}) when is_map(issue) do
    github_issue_id(github_issue_kind(issue), Map.get(issue, "number"))
  end

  defp github_webhook_issue_id("issues", %{"number" => number}) do
    github_issue_id(:issue, number)
  end

  defp github_webhook_issue_id(_event, _params), do: nil

  defp github_issue_kind(%{"pull_request" => pull_request}) when is_map(pull_request), do: :pull_request
  defp github_issue_kind(_issue), do: :issue

  defp github_issue_id(kind, number) when kind in [:issue, :pull_request] do
    case normalize_github_issue_number(number) do
      number when is_integer(number) and kind == :pull_request -> "github:pr:#{number}"
      number when is_integer(number) -> "github:issue:#{number}"
      nil -> nil
    end
  end

  defp normalize_github_issue_number(number) when is_integer(number) and number > 0, do: number

  defp normalize_github_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_github_issue_number(_number), do: nil
end
