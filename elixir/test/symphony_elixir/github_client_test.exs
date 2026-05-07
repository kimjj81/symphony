defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client

  test "normalizes GitHub issues with Symphony state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert {:ok, issue} =
             Client.normalize_issue_for_test(%{
               "number" => 12,
               "title" => "Plan analytics",
               "body" => "Break down analytics work",
               "state" => "open",
               "html_url" => "https://github.com/studiojin-dev/myven/issues/12",
               "labels" => [%{"name" => "sym:todo"}],
               "created_at" => "2026-04-29T00:00:00Z",
               "updated_at" => "2026-04-29T00:00:00Z"
             })

    assert issue.id == "github:issue:12"
    assert issue.identifier == "#12"
    assert issue.kind == :issue
    assert issue.state == "Todo"
    assert issue.labels == ["sym:todo"]
  end

  test "normalizes GitHub pull requests with Symphony state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert {:ok, issue} =
             Client.normalize_issue_for_test(%{
               "number" => 7,
               "title" => "Implement health smoke test",
               "body" => "Implementation PR",
               "state" => "open",
               "html_url" => "https://github.com/studiojin-dev/myven/pull/7",
               "pull_request" => %{"url" => "https://api.github.com/repos/studiojin-dev/myven/pulls/7"},
               "labels" => [%{"name" => "sym:review"}]
             })

    assert issue.id == "github:pr:7"
    assert issue.identifier == "PR #7"
    assert issue.kind == :pull_request
    assert issue.state == "Review"
  end

  test "collects GitHub candidate issues by locally filtering Symphony labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    rework_pr = %{
      "number" => 29,
      "title" => "Rework requested",
      "state" => "open",
      "html_url" => "https://github.com/studiojin-dev/myven/pull/29",
      "pull_request" => %{"url" => "https://api.github.com/repos/studiojin-dev/myven/pulls/29"},
      "labels" => [%{"name" => "sym:rework"}]
    }

    human_review_pr = %{
      "number" => 30,
      "title" => "Waiting for a human",
      "state" => "open",
      "html_url" => "https://github.com/studiojin-dev/myven/pull/30",
      "pull_request" => %{"url" => "https://api.github.com/repos/studiojin-dev/myven/pulls/30"},
      "labels" => [%{"name" => "sym:human-review"}]
    }

    assert {:ok, [^rework_pr]} =
             Client.collect_issues_matching_labels_for_test(["sym:rework"], fn ->
               {:ok, [human_review_pr, rework_pr]}
             end)
  end

  test "skips GitHub issues without Symphony state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert :skip =
             Client.normalize_issue_for_test(%{
               "number" => 8,
               "title" => "Parked idea",
               "body" => "No Symphony label",
               "state" => "open",
               "html_url" => "https://github.com/studiojin-dev/myven/issues/8",
               "labels" => [%{"name" => "enhancement"}]
             })
  end

  test "skips GitHub issues with ambiguous Symphony state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert :skip =
             Client.normalize_issue_for_test(%{
               "number" => 9,
               "title" => "Conflicting state",
               "body" => "Two state labels",
               "state" => "open",
               "html_url" => "https://github.com/studiojin-dev/myven/issues/9",
               "labels" => [%{"name" => "sym:review"}, %{"name" => "sym:reviewing"}]
             })
  end

  test "rejects ambiguous Symphony state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert {:error, {:ambiguous_state_labels, states}} =
             Client.state_from_labels_for_test(["sym:todo", "sym:rework"])

    assert Enum.sort(states) == ["Rework", "Todo"]
  end
end
