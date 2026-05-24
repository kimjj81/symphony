defmodule SymphonyElixir.CodexTaskClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.TaskClassifier
  alias SymphonyElixir.Tracker.Issue

  test "classifies clear single file edits" do
    issue = %Issue{
      title: "Update lib/symphony_elixir/codex/app_server.ex",
      description: "명확한 단일 파일 수정",
      state: "In Progress",
      kind: :issue
    }

    assert TaskClassifier.classify(issue) == "single_file_edit"
  end

  test "classifies bugs with test failure logs" do
    issue = %Issue{
      title: "Fix checkout error",
      description: "테스트 실패 로그 includes stack trace from the failing test.",
      labels: ["bug"],
      kind: :pull_request
    }

    assert TaskClassifier.classify(issue) == "bug_with_test_log"
  end

  test "classifies unknown-cause bugs" do
    issue = %Issue{
      title: "Fix intermittent billing error",
      description: "원인 불명이라 먼저 root cause 진단이 필요하다.",
      labels: ["backend"]
    }

    assert TaskClassifier.classify(issue) == "unknown_bug"
  end

  test "classifies multi-file refactors" do
    issue = %Issue{
      title: "Refactor worker dispatch",
      description: "다중 파일 구조 변경으로 queue와 runner를 함께 정리한다."
    }

    assert TaskClassifier.classify(issue) == "multi_file_refactor"
  end

  test "classifies features without test mentions" do
    issue = %Issue{
      title: "Add operator export",
      description: "새 기능 추가: operator 화면에서 CSV export를 제공한다."
    }

    assert TaskClassifier.classify(issue) == "feature_without_tests"
  end

  test "falls back to default" do
    issue = %Issue{
      title: "Discuss tracker handoff",
      description: "Clarify operating notes and next decision."
    }

    assert TaskClassifier.classify(issue) == "default"
  end

  test "accepts plain tracker maps with string or atom keys" do
    assert TaskClassifier.classify(%{
             "title" => "Fix API error",
             "description" => "log output includes traceback",
             "labels" => ["backend"]
           }) == "bug_with_test_log"

    assert TaskClassifier.classify(%{
             title: "Refactor queue modules",
             description: "multiple files need restructure",
             labels: ["maintenance"]
           }) == "multi_file_refactor"
  end

  test "handles missing or non-map tracker payloads as default" do
    assert TaskClassifier.classify(%{"title" => "Discuss handoff"}) == "default"
    assert TaskClassifier.classify("Discuss handoff") == "default"
  end
end
