defmodule SymphonyElixir.Codex.OrchestrationBrief do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder}
  alias SymphonyElixir.Tracker.Issue

  @max_bytes 8_192

  @output_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "live_head",
      "unresolved_feedback",
      "focused_verification",
      "stop_conditions"
    ],
    "properties" => %{
      "live_head" => %{"type" => ["string", "null"]},
      "unresolved_feedback" => %{"type" => "array", "items" => %{"type" => "string"}},
      "focused_verification" => %{"type" => "array", "items" => %{"type" => "string"}},
      "stop_conditions" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }

  @spec generate(Path.t(), Issue.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def generate(workspace, %Issue{} = issue, opts \\ []) do
    generator = Keyword.get(opts, :brief_generator)

    if is_function(generator, 2),
      do: normalize_generated(generator.(workspace, issue), issue),
      else: generate_with_codex(workspace, issue, opts)
  end

  @spec fallback(Issue.t()) :: String.t()
  def fallback(%Issue{} = issue) do
    unresolved_feedback =
      if normalize_lane(issue.state) == "rework" do
        "use only tracker feedback already present in the workflow context; do not query GitHub; stop if actionable Rework feedback is unavailable"
      else
        "use only tracker feedback already present in the workflow context; do not query GitHub"
      end

    """
    live_head: use the tracker head metadata already supplied; stop before writes if it is unknown
    unresolved_feedback: #{unresolved_feedback}
    focused_verification: run git diff --check and only tests or static checks directly covering changed files
    stop_conditions: report remote-head drift, interactive-only requirements, or missing credible focused verification as facts; do not choose an execution lane or semantic outcome
    """
    |> String.trim()
  end

  @doc false
  @spec decode_for_test(String.t() | nil, Issue.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def decode_for_test(text, %Issue{} = issue), do: decode_brief(text, issue)

  @doc false
  @spec normalize_for_test(term(), Issue.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def normalize_for_test(result, %Issue{} = issue), do: normalize_generated(result, issue)

  defp normalize_lane(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_lane(_state), do: ""

  defp generate_with_codex(workspace, issue, opts) do
    settings = Config.settings!()
    profile = Map.fetch!(settings.codex.task_profiles, "orchestration")
    worker_host = Keyword.get(opts, :worker_host)

    session_opts = [
      worker_host: worker_host,
      codex_command: Map.fetch!(profile, "command"),
      runtime_overrides: %{
        thread_sandbox: "read-only",
        turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
      }
    ]

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      try do
        prompt = preflight_prompt(issue, opts)

        case AppServer.run_turn(session, prompt, issue,
               model: Map.fetch!(profile, "model"),
               effort: Map.fetch!(profile, "effort"),
               output_schema: @output_schema,
               on_message: Keyword.get(opts, :on_message, fn _ -> :ok end)
             ) do
          {:ok, %{result: payload} = turn_result} ->
            turn_result
            |> Map.get(:final_agent_message)
            |> Kernel.||(AppServer.final_agent_message(payload))
            |> decode_brief(issue)

          {:error, reason} ->
            {:error, reason}
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp preflight_prompt(issue, opts) do
    rendered_workflow = PromptBuilder.build_prompt(issue, attempt: Keyword.get(opts, :attempt))

    """
    You are Symphony's read-only orchestration preflight agent. Do not edit files, run tests, post
    comments, change labels, push, or merge. Your read-only sandbox applies only to this preflight
    turn. You do not decide the downstream worker's execution lane, write authority, allowed scope,
    tracker transition, or semantic outcome; Symphony derives those deterministically from the
    tracker item.

    Read the workflow below, the relevant local conductor/review/GitHub-review skill entrypoints
    and references exactly once, and current live pull-request feedback when available. Return only
    the requested compact evidence snapshot: live head, unresolved feedback, focused verification,
    and factual stop conditions. Prefer the current live head and unresolved feedback over stale
    workpad text. The result must be actionable without reopening those long skill or reference
    documents and must stay below #{@max_bytes} bytes.

    WORKFLOW AND TRACKER CONTEXT
    #{rendered_workflow}
    """
  end

  defp decode_brief(nil, _issue), do: {:error, :missing_orchestration_brief}

  defp decode_brief(text, issue) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, brief} when is_map(brief) -> normalize_generated({:ok, brief}, issue)
      {:error, reason} -> {:error, {:invalid_orchestration_brief_json, reason}}
      _ -> {:error, :invalid_orchestration_brief}
    end
  end

  defp normalize_generated({:ok, brief}, issue) when is_map(brief) do
    rendered = render(brief)

    if byte_size(rendered) <= @max_bytes do
      {:ok, rendered, %{source: :agent, bytes: byte_size(rendered), lane: issue.state}}
    else
      {:error, {:orchestration_brief_too_large, byte_size(rendered)}}
    end
  end

  defp normalize_generated({:ok, brief}, issue) when is_binary(brief) do
    if byte_size(brief) <= @max_bytes do
      {:ok, brief, %{source: :agent, bytes: byte_size(brief), lane: issue.state}}
    else
      {:error, {:orchestration_brief_too_large, byte_size(brief)}}
    end
  end

  defp normalize_generated({:error, reason}, _issue), do: {:error, reason}
  defp normalize_generated(other, _issue), do: {:error, {:invalid_orchestration_brief_result, other}}

  defp render(brief) do
    [
      {"live_head", Map.get(brief, "live_head") || Map.get(brief, :live_head)},
      {"unresolved_feedback", Map.get(brief, "unresolved_feedback") || Map.get(brief, :unresolved_feedback)},
      {"focused_verification", Map.get(brief, "focused_verification") || Map.get(brief, :focused_verification)},
      {"stop_conditions", Map.get(brief, "stop_conditions") || Map.get(brief, :stop_conditions)}
    ]
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{format_value(value)}" end)
  end

  defp format_value(nil), do: "unknown"
  defp format_value(values) when is_list(values), do: Enum.map_join(values, " | ", &to_string/1)
  defp format_value(value), do: to_string(value)
end
