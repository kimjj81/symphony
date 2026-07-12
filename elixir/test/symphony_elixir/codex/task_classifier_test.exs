defmodule SymphonyElixir.Codex.TaskClassifierTest do
  use ExUnit.Case

  alias SymphonyElixir.Codex.TaskClassifier

  test "classifies planning tasks as planning" do
    assert TaskClassifier.classify(%{
             "title" => "다음 분기 로드맵 정리",
             "description" => "요구사항과 구현 범위를 포함한 계획안 작성"
           }) == "planning"
  end

  test "classifies review tasks as review" do
    assert TaskClassifier.classify(%{
             "title" => "PR 리뷰",
             "description" => "이 변경사항은 리뷰 진행해 주세요"
           }) == "review"
  end

  test "classifies exploration tasks as exploration" do
    assert TaskClassifier.classify(%{
             "title" => "인증 흐름 조사",
             "description" => "현재 동작을 탐색하고 관련 코드를 분석해 주세요"
           }) == "exploration"
  end

  test "keeps ordinary work in default profile" do
    assert TaskClassifier.classify(%{
             "title" => "문서 정리",
             "description" => "가독성을 조금 개선합니다"
           }) == "default"
  end

  test "single file edit classification remains available" do
    assert TaskClassifier.classify(%{
             "title" => "config.exs",
             "description" => "config.exs 한 파일만 수정"
           }) == "single_file_edit"
  end
end
