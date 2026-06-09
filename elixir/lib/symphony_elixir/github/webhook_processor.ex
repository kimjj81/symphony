defmodule SymphonyElixir.GitHub.WebhookProcessor do
  @moduledoc """
  Shared GitHub webhook handling for HTTP and NATS deliveries.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixirWeb.Presenter

  @refresh_events ~w(issues pull_request pull_request_review pull_request_review_comment issue_comment)
  @refresh_actions ~w(labeled unlabeled closed reopened synchronize submitted created)
  @follow_up_refresh_ms 2_000

  @type result :: {:ok, map()} | {:ignored, map()} | {:error, :unavailable}

  @spec handle_event(String.t(), map(), keyword()) :: result()
  def handle_event(event, payload, opts \\ []) when is_binary(event) and is_map(payload) do
    action = payload |> Map.get("action") |> to_string()
    issue_id = issue_id(event, payload)

    sync_webhook_state(event, action, payload, issue_id, opts)

    if refresh_event?(event, action) do
      refresh(event, action, issue_id, opts)
    else
      {:ignored, %{event: event, action: action}}
    end
  end

  @spec issue_id(String.t(), map()) :: String.t() | nil
  def issue_id("pull_request", %{"pull_request" => %{"number" => number}}) do
    github_issue_id(:pull_request, number)
  end

  def issue_id("pull_request", %{"number" => number}) do
    github_issue_id(:pull_request, number)
  end

  def issue_id("pull_request_review", %{"pull_request" => %{"number" => number}}) do
    github_issue_id(:pull_request, number)
  end

  def issue_id("pull_request_review_comment", %{"pull_request" => %{"number" => number}}) do
    github_issue_id(:pull_request, number)
  end

  def issue_id("issue_comment", %{"issue" => issue}) when is_map(issue) do
    github_issue_id(github_issue_kind(issue), Map.get(issue, "number"))
  end

  def issue_id("issues", %{"issue" => issue}) when is_map(issue) do
    github_issue_id(github_issue_kind(issue), Map.get(issue, "number"))
  end

  def issue_id("issues", %{"number" => number}) do
    github_issue_id(:issue, number)
  end

  def issue_id(_event, _payload), do: nil

  @spec refresh_event?(String.t(), String.t()) :: boolean()
  def refresh_event?(event, action) do
    event in @refresh_events and action in @refresh_actions
  end

  defp sync_webhook_state(event, action, payload, issue_id, opts) do
    if github_tracker?(opts) do
      sync_fun = Keyword.get(opts, :sync_fun, &GitHubAdapter.sync_webhook_state/3)

      case sync_fun.(event, action, payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("GitHub webhook state sync failed event=#{event} action=#{action} issue_id=#{inspect(issue_id)} reason=#{inspect(reason)}")

          :ok
      end
    else
      :ok
    end
  end

  defp github_tracker?(opts) do
    case Keyword.fetch(opts, :tracker_kind) do
      {:ok, kind} -> kind == "github"
      :error -> match?({:ok, %{tracker: %{kind: "github"}}}, Config.settings())
    end
  end

  defp refresh(event, action, issue_id, opts) do
    refresh_fun = Keyword.get(opts, :refresh_fun)

    result =
      if is_function(refresh_fun, 1) do
        refresh_fun.(issue_id)
      else
        opts
        |> Keyword.get(:orchestrator, SymphonyElixir.Orchestrator)
        |> Presenter.webhook_refresh_payload(Keyword.get(opts, :follow_up_delay_ms, @follow_up_refresh_ms), issue_id)
      end

    case result do
      {:ok, payload} -> {:ok, Map.merge(payload, response_metadata(event, action, issue_id))}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp response_metadata(event, action, issue_id) when is_binary(issue_id) do
    %{event: event, action: action, issue_id: issue_id}
  end

  defp response_metadata(event, action, _issue_id), do: %{event: event, action: action}

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
