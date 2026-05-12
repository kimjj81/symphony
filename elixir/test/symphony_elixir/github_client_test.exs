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

  test "creates an implementation pull request for a planned GitHub issue" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil,
      workspace_base_ref: "origin/main"
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      params = Keyword.get(opts, :params)
      json = Keyword.get(opts, :json)

      send(test_pid, {:github_request, method, path, params, json})

      case {method, path} do
        {:get, "/repos/studiojin-dev/myven/pulls"} ->
          assert params == %{state: "open", head: "studiojin-dev:symphony/_37", per_page: 1}
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_37"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/main"} ->
          github_response(200, %{"object" => %{"sha" => "base-sha"}})

        {:get, "/repos/studiojin-dev/myven/git/commits/base-sha"} ->
          github_response(200, %{"tree" => %{"sha" => "tree-sha"}})

        {:post, "/repos/studiojin-dev/myven/git/commits"} ->
          assert json == %{
                   message: "chore: prepare issue #37 implementation PR",
                   tree: "tree-sha",
                   parents: ["base-sha"],
                   author: %{
                     name: "Symphony",
                     email: "symphony@users.noreply.github.com"
                   }
                 }

          github_response(201, %{"sha" => "empty-sha"})

        {:post, "/repos/studiojin-dev/myven/git/refs"} ->
          assert json == %{ref: "refs/heads/symphony/_37", sha: "empty-sha"}
          github_response(201, %{"ref" => "refs/heads/symphony/_37", "object" => %{"sha" => "empty-sha"}})

        {:post, "/repos/studiojin-dev/myven/pulls"} ->
          assert json.head == "symphony/_37"
          assert json.base == "main"
          assert json.title == "Issue #37: Default empty strings"
          assert json.body =~ "https://github.com/studiojin-dev/myven/issues/37"
          assert json.body =~ "Closes #37"

          github_response(201, %{"number" => 88})

        {:get, "/repos/studiojin-dev/myven/issues/88"} ->
          issue_fetch_count = Process.get(:github_client_test_issue_88_fetch_count, 0) + 1
          Process.put(:github_client_test_issue_88_fetch_count, issue_fetch_count)

          labels =
            if issue_fetch_count == 1 do
              []
            else
              [%{"name" => "sym:planned"}]
            end

          github_response(200, raw_pull_request_issue(88, labels))

        {:get, "/repos/studiojin-dev/myven/labels/sym%3Aplanned"} ->
          github_response(200, %{"name" => "sym:planned"})

        {:post, "/repos/studiojin-dev/myven/issues/88/labels"} ->
          assert json == %{labels: ["sym:planned"]}
          github_response(200, [%{"name" => "sym:planned"}])

        {:get, "/repos/studiojin-dev/myven/pulls/88"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_37"}, "merged" => false})
      end
    end)

    issue = %Issue{
      id: "github:issue:37",
      identifier: "#37",
      title: "Default empty strings",
      description: "Use real defaults instead of ad-hoc blank strings.",
      state: "Planned",
      kind: :issue,
      url: "https://github.com/studiojin-dev/myven/issues/37"
    }

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(issue)

    assert pull_request.id == "github:pr:88"
    assert pull_request.identifier == "PR #88"
    assert pull_request.state == "Planned"
    assert pull_request.kind == :pull_request
    assert pull_request.branch_name == "symphony/_37"

    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, pull_request_json}
    assert pull_request_json.draft == false
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

  defp github_response(status, body), do: {:ok, %Req.Response{status: status, body: body}}

  defp raw_pull_request_issue(number, labels) do
    %{
      "number" => number,
      "title" => "Issue #37: Default empty strings",
      "body" => "Implementation PR",
      "state" => "open",
      "html_url" => "https://github.com/studiojin-dev/myven/pull/#{number}",
      "pull_request" => %{"url" => "https://api.github.com/repos/studiojin-dev/myven/pulls/#{number}"},
      "labels" => labels,
      "created_at" => "2026-05-10T00:00:00Z",
      "updated_at" => "2026-05-10T00:00:00Z"
    }
  end
end
