defmodule SymphonyElixir.Codex.TaskClassifier do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @type task_type ::
          String.t()

  @spec classify(Issue.t() | map()) :: task_type()
  def classify(issue) do
    issue
    |> classifier_context()
    |> matching_task_type()
  end

  defp classifier_context(issue) do
    %{
      body_text: issue_body_text(issue),
      combined_text: issue_text(issue)
    }
  end

  defp matching_task_type(context) do
    [
      {"feature_without_tests", feature_without_tests?(context)},
      {"multi_file_refactor", multi_file_refactor?(context)},
      {"unknown_bug", unknown_bug_task?(context)},
      {"bug_with_test_log", bug_with_test_log?(context)},
      {"unknown_bug", bug_task?(context.combined_text)},
      {"single_file_edit", single_file_task?(context.combined_text)}
    ]
    |> Enum.find_value("default", fn
      {task_type, true} -> task_type
      {_task_type, false} -> nil
    end)
  end

  defp feature_without_tests?(context) do
    feature_task?(context.combined_text) and not test_mentioned?(context.body_text)
  end

  defp multi_file_refactor?(context) do
    refactor_task?(context.combined_text) and multi_file_task?(context.combined_text)
  end

  defp unknown_bug_task?(context) do
    bug_task?(context.combined_text) and unknown_bug?(context.combined_text)
  end

  defp bug_with_test_log?(context) do
    bug_task?(context.combined_text) and test_log_signal?(context.combined_text)
  end

  defp issue_body_text(issue) do
    [issue_value(issue, :title), issue_value(issue, :description)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> normalize_text()
  end

  defp issue_text(issue) do
    [
      issue_value(issue, :kind),
      issue_value(issue, :state),
      issue_value(issue, :title),
      issue_value(issue, :description),
      issue_labels(issue)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &to_string/1)
    |> normalize_text()
  end

  defp issue_value(%Issue{} = issue, field), do: Map.get(issue, field)
  defp issue_value(issue, field) when is_map(issue), do: Map.get(issue, field) || Map.get(issue, to_string(field))
  defp issue_value(_issue, _field), do: nil

  defp issue_labels(%Issue{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []

  defp normalize_text(text) do
    String.downcase(text)
  end

  defp feature_task?(text) do
    regex_match?(text, ~r/\b(feature|add|new)\b/u) or
      String.contains?(text, ["기능 추가", "새 기능", "신규 기능", "추가 기능"])
  end

  defp refactor_task?(text) do
    regex_match?(text, ~r/\b(refactor|restructure)\b/u) or
      String.contains?(text, ["리팩터", "리팩토링", "구조 변경"])
  end

  defp multi_file_task?(text) do
    regex_match?(text, ~r/\b(multi[- ]file|multifile|multiple files|several files|many files)\b/u) or
      String.contains?(text, ["여러 파일", "다중 파일"])
  end

  defp bug_task?(text) do
    regex_match?(text, ~r/\b(bug|fix|error|fail|failure|failing)\b/u) or
      String.contains?(text, ["버그", "오류", "실패"])
  end

  defp unknown_bug?(text) do
    regex_match?(text, ~r/\b(unknown|root cause)\b/u) or
      String.contains?(text, ["원인 불명", "원인 미상", "원인 파악", "원인 분석"])
  end

  defp test_log_signal?(text) do
    regex_match?(text, ~r/\b(test failure|failing test|failed test|traceback|stack trace|stack|log|logs)\b/u) or
      String.contains?(text, ["실패 로그", "테스트 실패", "스택 트레이스"])
  end

  defp test_mentioned?(text) do
    regex_match?(text, ~r/\b(test|tests|testing|tested)\b/u) or String.contains?(text, "테스트")
  end

  defp single_file_task?(text) do
    regex_match?(text, ~r/\b(single file|one file)\b/u) or
      String.contains?(text, ["단일 파일", "한 파일"]) or
      length(path_like_tokens(text)) == 1
  end

  defp path_like_tokens(text) do
    ~r/(?:^|\s)(?!https?:\/\/)([\w.\/-]+\.(?:ex|exs|md|js|jsx|ts|tsx|py|rb|go|rs|java|kt|swift|css|html|json|ya?ml|toml|sh|sql)(?::\d+)?)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp regex_match?(text, regex), do: Regex.match?(regex, text)
end
