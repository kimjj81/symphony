defmodule SymphonyElixir.Notifications.Cmux do
  @moduledoc """
  Sends issue state transition notifications to cmux.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker.Issue}

  @max_title_length 120
  @max_subtitle_length 120
  @max_body_length 1_000

  @type command_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec notify_state?(String.t() | nil) :: boolean()
  def notify_state?(state_name) when is_binary(state_name) do
    settings = Config.settings!().notifications.cmux
    normalized_state = normalize_state(state_name)

    Enum.any?(settings.notify_states, &(normalize_state(&1) == normalized_state))
  end

  def notify_state?(_state_name), do: false

  @spec send_issue_state_transition(Issue.t(), String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def send_issue_state_transition(%Issue{} = issue, previous_state, new_state, opts \\ []) do
    settings = Config.settings!().notifications.cmux

    cond do
      not settings.enabled ->
        :ok

      not is_binary(settings.command) or String.trim(settings.command) == "" ->
        :ok

      not notify_state?(new_state) ->
        :ok

      true ->
        do_send_issue_state_transition(settings.command, issue, previous_state, new_state, opts)
    end
  end

  defp do_send_issue_state_transition(command, issue, previous_state, new_state, opts) do
    command_fun = Keyword.get(opts, :command_fun) || Application.get_env(:symphony_elixir, :cmux_notify_fun, &System.cmd/3)
    {title, subtitle, body} = build_notification(issue, previous_state, new_state)

    args = ["notify", "--title", title, "--subtitle", subtitle, "--body", body]

    try do
      case command_fun.(command, args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:cmux_notify_status, status, String.trim(to_string(output))}}
      end
    rescue
      error ->
        {:error, {:cmux_notify_exception, error}}
    end
  end

  defp build_notification(%Issue{} = issue, previous_state, new_state) do
    tracker = issue.metadata[:tracker] || issue.metadata["tracker"] || "tracker"
    identifier = issue.identifier || issue.id || "unknown issue"
    title = truncate("Symphony #{identifier}", @max_title_length)
    subtitle = truncate("#{format_state(previous_state)} -> #{format_state(new_state)}", @max_subtitle_length)

    body =
      [
        issue.title || "Untitled",
        "tracker: #{tracker}",
        issue.url
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n")
      |> truncate(@max_body_length)

    {title, subtitle, body}
  end

  defp truncate(value, max_length) do
    value = to_string(value)

    if String.length(value) <= max_length do
      value
    else
      String.slice(value, 0, max_length - 3) <> "..."
    end
  end

  defp format_state(state) when is_binary(state) and state != "", do: state
  defp format_state(_state), do: "unknown"

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""

  @spec log_result(:ok | {:error, term()}, Issue.t(), String.t() | nil) :: :ok
  def log_result(:ok, _issue, _new_state), do: :ok

  def log_result({:error, reason}, %Issue{} = issue, new_state) do
    Logger.warning("cmux notification failed for issue_id=#{issue.id} issue_identifier=#{issue.identifier} state=#{inspect(new_state)} reason=#{inspect(reason)}")

    :ok
  end
end
