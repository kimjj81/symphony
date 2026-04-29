defmodule SymphonyElixir.Notifications.Discord do
  @moduledoc """
  Sends issue state transition notifications to a Discord webhook.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker.Issue}

  @max_content_length 1_900

  @type request_fun :: (keyword() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec notify_state?(String.t() | nil) :: boolean()
  def notify_state?(state_name) when is_binary(state_name) do
    settings = Config.settings!().notifications.discord
    normalized_state = normalize_state(state_name)

    Enum.any?(settings.notify_states, &(normalize_state(&1) == normalized_state))
  end

  def notify_state?(_state_name), do: false

  @spec send_issue_state_transition(Issue.t(), String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def send_issue_state_transition(%Issue{} = issue, previous_state, new_state, opts \\ []) do
    settings = Config.settings!().notifications.discord

    cond do
      not settings.enabled ->
        :ok

      not is_binary(settings.webhook_url) ->
        :ok

      not notify_state?(new_state) ->
        :ok

      true ->
        do_send_issue_state_transition(settings.webhook_url, issue, previous_state, new_state, opts)
    end
  end

  defp do_send_issue_state_transition(webhook_url, issue, previous_state, new_state, opts) do
    request_fun =
      Keyword.get(opts, :request_fun) ||
        Application.get_env(:symphony_elixir, :discord_request_fun, &Req.request/1)

    payload = %{content: build_content(issue, previous_state, new_state)}

    case request_fun.(method: :post, url: webhook_url, json: payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:discord_webhook_status, status, body}}

      {:error, reason} ->
        {:error, {:discord_webhook_request, reason}}
    end
  end

  defp build_content(%Issue{} = issue, previous_state, new_state) do
    tracker = issue.metadata[:tracker] || issue.metadata["tracker"] || "tracker"
    identifier = issue.identifier || issue.id || "unknown issue"
    title = issue.title || "Untitled"
    url_line = if is_binary(issue.url) and issue.url != "", do: "\n#{issue.url}", else: ""

    """
    **Symphony state changed**
    #{identifier}: #{title}
    #{format_state(previous_state)} -> #{format_state(new_state)}
    tracker: #{tracker}#{url_line}
    """
    |> String.trim()
    |> truncate_content()
  end

  defp format_state(state) when is_binary(state) and state != "", do: state
  defp format_state(_state), do: "unknown"

  defp truncate_content(content) do
    if String.length(content) <= @max_content_length do
      content
    else
      String.slice(content, 0, @max_content_length - 3) <> "..."
    end
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""

  @spec log_result(:ok | {:error, term()}, Issue.t(), String.t() | nil) :: :ok
  def log_result(:ok, _issue, _new_state), do: :ok

  def log_result({:error, reason}, %Issue{} = issue, new_state) do
    Logger.warning("Discord notification failed for issue_id=#{issue.id} issue_identifier=#{issue.identifier} state=#{inspect(new_state)} reason=#{inspect(reason)}")

    :ok
  end
end
