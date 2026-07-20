defmodule SymphonyElixir.Forgejo.WebhookProcessor do
  @moduledoc """
  Shared Forgejo webhook handling for HTTP deliveries.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Forgejo.Client
  alias SymphonyElixirWeb.Presenter

  @refresh_events ~w(issues pull_request pull_request_review pull_request_review_comment issue_comment)
  @refresh_actions ~w(labeled unlabeled label_updated closed reopened synchronize synchronized submitted created)
  @follow_up_refresh_ms 2_000

  @type result :: {:ok, map()} | {:ignored, map()} | {:error, :unavailable}

  @spec handle_event(String.t(), map(), keyword()) :: result()
  def handle_event(event, payload, opts \\ []) when is_binary(event) and is_map(payload) do
    action = payload |> Map.get("action") |> to_string()
    issue_id = issue_id(event, payload)

    case validate_repository(payload, opts) do
      {:ignore, reason} ->
        {:ignored, %{event: event, action: action, reason: reason}}

      :ok ->
        handle_valid_event(event, action, payload, issue_id, opts)
    end
  end

  defp handle_valid_event(event, action, payload, issue_id, opts) do
    case ingest_webhook_intent(event, action, payload, issue_id, opts) do
      :ok ->
        if refresh_event?(event, action) do
          refresh(event, action, issue_id, opts)
        else
          {:ignored, %{event: event, action: action}}
        end

      :duplicate ->
        {:ignored, %{event: event, action: action, reason: :duplicate_delivery}}

      {:conflict, reason} ->
        {:ignored, %{event: event, action: action, reason: reason}}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @spec issue_id(String.t(), map()) :: String.t() | nil
  def issue_id("pull_request", %{"pull_request" => %{"number" => number}}) do
    forgejo_issue_id(:pull_request, number)
  end

  def issue_id("pull_request", %{"number" => number}) do
    forgejo_issue_id(:pull_request, number)
  end

  def issue_id("pull_request_review", %{"pull_request" => %{"number" => number}}) do
    forgejo_issue_id(:pull_request, number)
  end

  def issue_id("pull_request_review_comment", %{"pull_request" => %{"number" => number}}) do
    forgejo_issue_id(:pull_request, number)
  end

  def issue_id("issue_comment", %{"issue" => issue}) when is_map(issue) do
    forgejo_issue_id(forgejo_issue_kind(issue), Map.get(issue, "number"))
  end

  def issue_id("issues", %{"issue" => issue}) when is_map(issue) do
    forgejo_issue_id(forgejo_issue_kind(issue), Map.get(issue, "number"))
  end

  def issue_id("issues", %{"number" => number}) do
    forgejo_issue_id(:issue, number)
  end

  def issue_id(_event, _payload), do: nil

  @spec refresh_event?(String.t(), String.t()) :: boolean()
  def refresh_event?(event, action) do
    event in @refresh_events and action in @refresh_actions
  end

  @doc """
  Converts a Forgejo delivery into an immutable tracker intent.

  This function deliberately performs no tracker mutation. State policy and
  projection are owned by the orchestrator/state manager.
  """
  @spec normalize_intent(String.t(), String.t(), map()) :: {:ok, map()} | :ignore
  def normalize_intent(event, action, payload) when is_map(payload) do
    case normalize_intents(event, action, payload) do
      [intent] -> {:ok, intent}
      _ -> :ignore
    end
  end

  @doc false
  @spec normalize_intents(String.t(), String.t(), map()) :: [map()]
  def normalize_intents(event, action, payload) when is_map(payload) do
    event
    |> normalized_intents(action, payload)
    |> Enum.sort_by(&intent_sort_key/1)
  end

  def normalize_intents(_event, _action, _payload), do: []

  defp normalized_intents(event, action, payload)
       when event in ["issues", "pull_request"] and action in ["labeled", "unlabeled", "label_updated"] do
    payload
    |> label_changes(action)
    |> Enum.flat_map(fn %{action: label_action, label: label} ->
      case event
           |> intent_base(label_action, payload)
           |> normalize_label_intent(Map.put(payload, "label", %{"name" => label})) do
        {:ok, intent} -> [intent]
        :ignore -> []
      end
    end)
  end

  defp normalized_intents("issues" = event, "closed" = action, payload) do
    [
      Map.merge(intent_base(event, action, payload), %{
        kind: :issue_closed,
        state_reason: get_in(payload, ["issue", "state_reason"])
      })
    ]
  end

  defp normalized_intents("issues" = event, "reopened" = action, payload),
    do: [Map.put(intent_base(event, action, payload), :kind, :item_reopened)]

  defp normalized_intents("pull_request" = event, "closed" = action, payload) do
    [
      Map.merge(intent_base(event, action, payload), %{
        kind: :pull_request_closed,
        merged: get_in(payload, ["pull_request", "merged"]) == true
      })
    ]
  end

  defp normalized_intents("pull_request" = event, "reopened" = action, payload),
    do: [Map.put(intent_base(event, action, payload), :kind, :item_reopened)]

  defp normalized_intents("pull_request" = event, "synchronize" = action, payload) do
    [
      Map.merge(intent_base(event, action, payload), %{
        kind: :head_updated,
        head_oid: get_in(payload, ["pull_request", "head", "sha"])
      })
    ]
  end

  defp normalized_intents("pull_request" = event, "synchronized", payload),
    do: normalized_intents(event, "synchronize", payload)

  defp normalized_intents("pull_request_review" = event, "submitted" = action, payload) do
    [
      Map.merge(intent_base(event, action, payload), %{
        kind: :review_submitted,
        review_state: get_in(payload, ["review", "state"])
      })
    ]
  end

  defp normalized_intents("pull_request_review_comment" = event, "created" = action, payload),
    do: [Map.put(intent_base(event, action, payload), :kind, :review_feedback_detected)]

  defp normalized_intents(_event, _action, _payload), do: []

  defp intent_base(event, action, payload) do
    %{
      source: :forgejo_webhook,
      event: event,
      action: action,
      issue_id: issue_id(event, payload),
      actor: webhook_actor(payload)
    }
  end

  defp ingest_webhook_intent(event, action, payload, issue_id, opts) do
    if forgejo_tracker?(opts) do
      intents = normalize_intents(event, action, payload)

      if conflicting_operator_requests?(intents) do
        Logger.warning("Forgejo webhook delivery contains conflicting operator requests event=#{event} action=#{action} issue_id=#{inspect(issue_id)}")
        {:conflict, :conflicting_label_changes}
      else
        intents
        |> attach_delivery_ids(opts)
        |> ingest_intents(event, action, issue_id, opts)
      end
    else
      :ok
    end
  end

  defp ingest_intents([], _event, _action, _issue_id, _opts), do: :ok

  defp ingest_intents(intents, event, action, issue_id, opts) do
    intent_fun = Keyword.get(opts, :intent_fun)

    Enum.reduce_while(intents, :duplicate, fn intent, result ->
      case ingest_intent(intent_fun, intent) do
        {:error, reason} ->
          Logger.warning("Forgejo webhook intent ingestion failed event=#{event} action=#{action} issue_id=#{inspect(issue_id)} reason=#{inspect(reason)}")
          {:halt, {:error, reason}}

        :unavailable ->
          {:halt, {:error, :unavailable}}

        {:noop, :already_applied} ->
          {:cont, result}

        _other ->
          {:cont, :ok}
      end
    end)
  end

  defp ingest_intent(intent_fun, intent) when is_function(intent_fun, 1), do: intent_fun.(intent)
  defp ingest_intent(_intent_fun, _intent), do: :ok

  defp attach_delivery_ids(intents, opts) do
    case Keyword.get(opts, :delivery_id) do
      delivery_id when is_binary(delivery_id) and delivery_id != "" ->
        intents
        |> Enum.with_index(1)
        |> Enum.map(fn {intent, index} -> Map.put(intent, :delivery_id, "#{delivery_id}:#{index}") end)

      _ ->
        intents
    end
  end

  defp conflicting_operator_requests?(intents) do
    intents
    |> Enum.filter(&(&1.kind == :operator_transition_requested))
    |> Enum.map(& &1.requested_state)
    |> MapSet.new()
    |> MapSet.size()
    |> Kernel.>(1)
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
        observed_state = if base.action == "unlabeled", do: nil, else: observed_state

        {:ok, Map.merge(base, %{kind: kind, label: label, observed_state: observed_state})}

      :unmanaged ->
        :ignore
    end
  end

  defp label_changes(payload, action) do
    top_level_action = if action == "unlabeled", do: "unlabeled", else: "labeled"
    top_level = label_change(top_level_action, get_in(payload, ["label", "name"]))

    changes =
      case action do
        "labeled" ->
          label_changes_from(payload, "added", "labeled")

        "unlabeled" ->
          label_changes_from(payload, "removed", "unlabeled")

        "label_updated" ->
          label_changes_from(payload, "added", "labeled") ++
            label_changes_from(payload, "removed", "unlabeled")
      end

    [top_level | changes]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.action, String.downcase(&1.label)})
  end

  defp label_changes_from(payload, direction, action) do
    payload
    |> get_in(["changes", "labels", direction])
    |> List.wrap()
    |> Enum.map(&label_name/1)
    |> Enum.map(&label_change(action, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp label_change(action, label) when action in ["labeled", "unlabeled"] and is_binary(label) do
    label = String.trim(label)
    if label == "", do: nil, else: %{action: action, label: label}
  end

  defp label_change(_action, _label), do: nil

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(_label), do: nil

  defp intent_sort_key(intent) do
    {
      Map.get(intent, :action, ""),
      intent |> Map.get(:label, "") |> to_string() |> String.downcase(),
      Map.get(intent, :kind)
    }
  end

  defp self_write?(payload) do
    expected_login =
      case Config.settings() do
        {:ok, %{tracker: %{kind: "forgejo", bot_login: login}}}
        when is_binary(login) and login != "" ->
          login

        _ ->
          System.get_env("SYMPHONY_FORGEJO_BOT_LOGIN") || "symphony"
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

  defp forgejo_tracker?(opts) do
    case Keyword.fetch(opts, :tracker_kind) do
      {:ok, kind} -> kind == "forgejo"
      :error -> match?({:ok, %{tracker: %{kind: "forgejo"}}}, Config.settings())
    end
  end

  defp validate_repository(payload, opts) do
    if forgejo_tracker?(opts) do
      expected = Keyword.get_lazy(opts, :repository, &configured_repository/0)
      actual = get_in(payload, ["repository", "full_name"])

      expected_origin =
        opts
        |> Keyword.get_lazy(:endpoint_origin, &configured_endpoint_origin/0)
        |> endpoint_origin()

      actual_origin = payload_repository_origin(payload)

      if is_binary(expected) and is_binary(actual) and
           normalize_repository(expected) == normalize_repository(actual) and
           same_origin?(expected_origin, actual_origin),
         do: :ok,
         else: {:ignore, repository_mismatch_reason(expected, actual, expected_origin, actual_origin)}
    else
      {:ignore, :inactive_tracker}
    end
  end

  defp configured_repository do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "forgejo", owner: owner, repo: repo}}}
      when is_binary(owner) and is_binary(repo) ->
        owner <> "/" <> repo

      _ ->
        nil
    end
  end

  defp configured_endpoint_origin do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "forgejo", endpoint: endpoint}}} when is_binary(endpoint) ->
        endpoint

      _ ->
        nil
    end
  end

  defp payload_repository_origin(payload) do
    repository = Map.get(payload, "repository", %{})

    [Map.get(repository, "html_url"), Map.get(repository, "url"), Map.get(repository, "clone_url")]
    |> Enum.find_value(&endpoint_origin/1)
  end

  defp repository_mismatch_reason(expected, actual, _expected_origin, _actual_origin)
       when not (is_binary(expected) and is_binary(actual)),
       do: :repository_mismatch

  defp repository_mismatch_reason(expected, actual, expected_origin, actual_origin) do
    if normalize_repository(expected) != normalize_repository(actual),
      do: :repository_mismatch,
      else: if(same_origin?(expected_origin, actual_origin), do: :repository_mismatch, else: :instance_mismatch)
  end

  defp same_origin?(expected, actual) when is_tuple(expected) and is_tuple(actual), do: expected == actual

  defp same_origin?(_expected, _actual), do: false

  defp endpoint_origin(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      scheme = String.downcase(uri.scheme)
      {scheme, String.downcase(uri.host), uri.port || URI.default_port(scheme)}
    end
  end

  defp endpoint_origin(_), do: nil

  defp normalize_repository(repository), do: repository |> String.trim() |> String.downcase()

  defp refresh(event, action, issue_id, opts) do
    refresh_fun = Keyword.get(opts, :refresh_fun)

    result =
      if is_function(refresh_fun, 1) do
        refresh_fun.(issue_id)
      else
        opts
        |> Keyword.get(:orchestrator, SymphonyElixir.Orchestrator)
        |> Presenter.webhook_refresh_payload(
          Keyword.get(opts, :follow_up_delay_ms, @follow_up_refresh_ms),
          issue_id
        )
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

  defp forgejo_issue_kind(%{"pull_request" => pull_request}) when is_map(pull_request),
    do: :pull_request

  defp forgejo_issue_kind(_issue), do: :issue

  defp forgejo_issue_id(kind, number) when kind in [:issue, :pull_request] do
    case normalize_forgejo_issue_number(number) do
      number when is_integer(number) and kind == :pull_request -> "forgejo:pr:#{number}"
      number when is_integer(number) -> "forgejo:issue:#{number}"
      nil -> nil
    end
  end

  defp normalize_forgejo_issue_number(number) when is_integer(number) and number > 0, do: number

  defp normalize_forgejo_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_forgejo_issue_number(_number), do: nil
end
