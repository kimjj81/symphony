defmodule SymphonyElixir.GitHub.WebhookProcessor do
  @moduledoc """
  Shared GitHub webhook handling for HTTP and NATS deliveries.
  """

  require Logger

  alias SymphonyElixir.{Config, HostedGit}
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixirWeb.Presenter

  @refresh_events ~w(issues pull_request pull_request_review pull_request_review_comment issue_comment)
  @refresh_actions ~w(labeled unlabeled closed reopened synchronize submitted created)
  @follow_up_refresh_ms 2_000

  @type result :: {:ok, map()} | {:ignored, map()} | {:error, :unavailable}

  @spec handle_event(String.t(), map(), keyword()) :: result()
  def handle_event(event, payload, opts \\ []) when is_binary(event) and is_map(payload) do
    action = payload |> Map.get("action") |> to_string()
    issue_id = issue_id(event, payload)

    case ingest_webhook_intent(event, action, payload, issue_id, opts) do
      :ok ->
        if refresh_event?(event, action) do
          refresh(event, action, issue_id, opts)
        else
          {:ignored, %{event: event, action: action}}
        end

      {:error, _reason} ->
        {:error, :unavailable}
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

  @doc """
  Converts a GitHub delivery into an immutable tracker intent.

  This function deliberately performs no tracker mutation. State policy and
  projection are owned by the orchestrator/state manager.
  """
  @spec normalize_intent(String.t(), String.t(), map()) :: {:ok, map()} | :ignore
  def normalize_intent(event, action, payload)
      when event in ["issues", "pull_request"] and action in ["labeled", "unlabeled"] and is_map(payload) do
    event
    |> intent_base(action, payload)
    |> normalize_label_intent(payload)
  end

  def normalize_intent("issues" = event, "closed" = action, payload) when is_map(payload) do
    {:ok,
     Map.merge(intent_base(event, action, payload), %{
       kind: :issue_closed,
       state_reason: get_in(payload, ["issue", "state_reason"])
     })}
  end

  def normalize_intent("issues" = event, "reopened" = action, payload) when is_map(payload),
    do: {:ok, Map.put(intent_base(event, action, payload), :kind, :item_reopened)}

  def normalize_intent("pull_request" = event, "closed" = action, payload) when is_map(payload) do
    {:ok,
     Map.merge(intent_base(event, action, payload), %{
       kind: :pull_request_closed,
       merged: get_in(payload, ["pull_request", "merged"]) == true
     })}
  end

  def normalize_intent("pull_request" = event, "reopened" = action, payload) when is_map(payload),
    do: {:ok, Map.put(intent_base(event, action, payload), :kind, :item_reopened)}

  def normalize_intent("pull_request" = event, "synchronize" = action, payload) when is_map(payload) do
    {:ok,
     Map.merge(intent_base(event, action, payload), %{
       kind: :head_updated,
       head_oid: get_in(payload, ["pull_request", "head", "sha"])
     })}
  end

  def normalize_intent("pull_request_review" = event, "submitted" = action, payload) when is_map(payload) do
    {:ok,
     Map.merge(intent_base(event, action, payload), %{
       kind: :review_submitted,
       review_state: get_in(payload, ["review", "state"])
     })}
  end

  def normalize_intent("pull_request_review_comment" = event, "created" = action, payload) when is_map(payload) do
    if HostedGit.codex_review_comment?(payload),
      do: {:ok, Map.put(intent_base(event, action, payload), :kind, :review_feedback_detected)},
      else: :ignore
  end

  def normalize_intent(_event, _action, _payload), do: :ignore

  defp intent_base(event, action, payload) do
    %{
      source: :github_webhook,
      event: event,
      action: action,
      issue_id: issue_id(event, payload),
      actor: webhook_actor(payload)
    }
  end

  defp ingest_webhook_intent(event, action, payload, issue_id, opts) do
    with true <- github_tracker?(opts),
         {:ok, intent} <- normalize_intent(event, action, payload) do
      intent_fun = Keyword.get(opts, :intent_fun)

      result =
        if is_function(intent_fun, 1) do
          intent_fun.(intent)
        else
          :ok
        end

      case result do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("GitHub webhook intent ingestion failed event=#{event} action=#{action} issue_id=#{inspect(issue_id)} reason=#{inspect(reason)}")

          {:error, reason}

        :unavailable ->
          {:error, :unavailable}

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp normalize_label_intent(base, payload) do
    label = get_in(payload, ["label", "name"])

    case Client.classify_managed_label(label) do
      {:request, requested_state} when base.action == "labeled" ->
        {:ok,
         Map.merge(base, %{
           kind: :operator_transition_requested,
           label: label,
           request: request_key(label),
           requested_state: requested_state,
           request_action: base.action
         })}

      {:request, _requested_state} ->
        :ignore

      {:state, observed_state} ->
        kind = if self_write?(payload), do: :projection_echo, else: :state_projection_drift

        observed_state =
          if base.action == "unlabeled",
            do: nil,
            else: observed_state

        {:ok, Map.merge(base, %{kind: kind, label: label, observed_state: observed_state})}

      :unmanaged ->
        :ignore
    end
  end

  defp self_write?(payload) do
    expected_login =
      case Config.settings() do
        {:ok, %{tracker: %{kind: "github", bot_login: login}}} when is_binary(login) and login != "" -> login
        _ -> System.get_env("SYMPHONY_GITHUB_BOT_LOGIN") || "symphony[bot]"
      end

    case Map.get(payload, "sender", %{}) do
      %{"login" => login} when is_binary(login) ->
        String.downcase(login) == String.downcase(expected_login)

      _ ->
        false
    end
  end

  defp request_key("sym:request-planned"), do: :planned
  defp request_key("sym:request-rework"), do: :rework
  defp request_key("sym:request-merging"), do: :merging
  defp request_key("sym:request-human-review"), do: :human_review
  defp request_key("sym:request-canceled"), do: :canceled
  defp request_key("sym:request-duplicate"), do: :duplicate
  defp request_key("sym:request-reopen"), do: :reopen
  defp request_key(_label), do: :unknown

  defp webhook_actor(payload) do
    case Map.get(payload, "sender", %{}) do
      %{"login" => login} when is_binary(login) -> login
      _ -> nil
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
