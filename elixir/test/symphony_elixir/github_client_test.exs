defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client

  test "exposes Reworking and operator request label metadata" do
    assert Client.default_state_labels()["Reworking"] == "sym:reworking"
    assert Client.request_labels()["sym:request-reopen"] == "Human Review"

    assert {_, "Request that Symphony reopen this terminal item for human review."} =
             Client.managed_label_metadata()["sym:request-reopen"]

    assert Client.classify_managed_label("sym:request-rework") == {:request, "Rework"}
    assert Client.classify_managed_label("sym:reworking") == {:state, "Reworking"}
  end

  test "atomically projects a state while preserving non-state labels and consuming requests" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      json = Keyword.get(opts, :json)
      send(test_pid, {:github_projection_request, method, path, json})

      case {method, path} do
        {:get, "/repos/studiojin-dev/myven/issues/42"} ->
          github_response(
            200,
            raw_issue(42, "Projection", "", [
              %{"name" => "enhancement"},
              %{"name" => "sym:planned"},
              %{"name" => "sym:request-merging"}
            ])
          )

        {:get, "/repos/studiojin-dev/myven/labels/sym%3Amerging"} ->
          github_response(200, %{"name" => "sym:merging"})

        {:put, "/repos/studiojin-dev/myven/issues/42/labels"} ->
          assert json == %{labels: ["enhancement", "sym:merging"]}
          github_response(200, Enum.map(json.labels, &%{"name" => &1}))

        {:get, "/repos/studiojin-dev/myven/issues/42/labels"} ->
          github_response(200, [%{"name" => "enhancement"}, %{"name" => "sym:merging"}])
      end
    end)

    assert {:applied, %{state: "Merging", labels: ["enhancement", "sym:merging"]}} =
             Client.apply_state_projection("github:issue:42", "Planned", "Merging")

    assert_receive {:github_projection_request, :put, "/repos/studiojin-dev/myven/issues/42/labels", %{labels: ["enhancement", "sym:merging"]}}
  end

  test "returns conflict without writing when expected state is stale" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      send(test_pid, {:github_projection_request, method, path})
      github_response(200, raw_issue(43, "Conflict", "", [%{"name" => "sym:done"}]))
    end)

    assert {:conflict, %{state: "Done", expected_state: "Review", target_state: "Human Review"}} =
             Client.apply_state_projection("github:issue:43", "Review", "Human Review")

    refute_receive {:github_projection_request, :put, _}, 50
  end

  test "returns already_applied without rewriting a verified projection" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      send(test_pid, {:github_projection_request, method, path})
      github_response(200, raw_issue(44, "Noop", "", [%{"name" => "bug"}, %{"name" => "sym:reviewing"}]))
    end)

    assert {:already_applied, %{state: "Reviewing", labels: ["bug", "sym:reviewing"]}} =
             Client.apply_state_projection("github:pr:44", "Reviewing", "Reviewing")

    refute_receive {:github_projection_request, :put, _}, 50
  end

  test "closes an open issue when projecting Canceled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue_path = "/repos/studiojin-dev/myven/issues/49"

    stub_github_requests(self(), [
      {:get, issue_path, github_response(200, raw_issue(49, "Cancel", "", [%{"name" => "sym:human-review"}]))},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Acanceled", github_response(200, %{"name" => "sym:canceled"})},
      {:put, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:canceled"}])},
      {:get, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:canceled"}])},
      {:get, issue_path, github_response(200, %{"state" => "open"})},
      {:get, "#{issue_path}/sub_issues", github_response(200, [])},
      {:patch, issue_path, github_response(200, %{"state" => "closed", "state_reason" => "not_planned"})},
      {:get, issue_path, github_response(200, %{"state" => "closed", "state_reason" => "not_planned"})}
    ])

    assert {:applied, %{state: "Canceled", open_state: "closed"}} =
             Client.apply_state_projection("github:issue:49", "Human Review", "Canceled")

    assert_receive {:github_request, :patch, ^issue_path, nil, %{state: "closed", state_reason: "not_planned"}}
    assert_github_responses_consumed()
  end

  test "closes an open issue when projecting Done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue_path = "/repos/studiojin-dev/myven/issues/57"

    stub_github_requests(self(), [
      {:get, issue_path, github_response(200, raw_issue(57, "Complete", "", [%{"name" => "sym:merging"}]))},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Adone", github_response(200, %{"name" => "sym:done"})},
      {:put, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:get, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:get, issue_path, github_response(200, %{"state" => "open"})},
      {:get, "#{issue_path}/sub_issues", github_response(200, [])},
      {:patch, issue_path, github_response(200, %{"state" => "closed", "state_reason" => "completed"})},
      {:get, issue_path, github_response(200, %{"state" => "closed", "state_reason" => "completed"})}
    ])

    assert {:applied, %{state: "Done", open_state: "closed"}} =
             Client.apply_state_projection("github:issue:57", "Merging", "Done")

    assert_receive {:github_request, :patch, ^issue_path, nil, %{state: "closed", state_reason: "completed"}}
    assert_github_responses_consumed()
  end

  test "reopens a closed issue when consuming request-reopen into Human Review" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue_path = "/repos/studiojin-dev/myven/issues/50"
    labels_path = "#{issue_path}/labels"

    stub_github_requests(self(), [
      {:get, issue_path,
       github_response(
         200,
         raw_issue(
           50,
           "Reopen",
           "",
           [%{"name" => "sym:canceled"}, %{"name" => "sym:request-reopen"}],
           "closed"
         )
       )},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Ahuman-review", github_response(200, %{"name" => "sym:human-review"})},
      {:put, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:human-review"}])},
      {:get, "#{issue_path}/labels", github_response(200, [%{"name" => "sym:human-review"}])},
      {:get, issue_path, github_response(200, %{"state" => "closed", "state_reason" => "not_planned"})},
      {:patch, issue_path, github_response(200, %{"state" => "open"})},
      {:get, issue_path, github_response(200, %{"state" => "open"})}
    ])

    assert {:applied, %{state: "Human Review", labels: ["sym:human-review"], open_state: "open"}} =
             Client.apply_state_projection("github:issue:50", "Canceled", "Human Review")

    assert_receive {:github_request, :put, ^labels_path, nil, %{labels: ["sym:human-review"]}}
    assert_receive {:github_request, :patch, ^issue_path, nil, %{state: "open"}}
    assert_github_responses_consumed()
  end

  test "merges a pull request only at the expected head OID" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      json = Keyword.get(opts, :json)
      send(test_pid, {:github_merge_request, method, path, json})

      case {method, path} do
        {:get, "/repos/studiojin-dev/myven/pulls/45"} ->
          github_response(200, %{"merged" => false, "head" => %{"sha" => "expected-head"}})

        {:put, "/repos/studiojin-dev/myven/pulls/45/merge"} ->
          assert json == %{sha: "expected-head", merge_method: "squash"}
          github_response(200, %{"merged" => true, "sha" => "merge-sha"})
      end
    end)

    assert {:applied,
            %{
              issue_id: "github:pr:45",
              merged: true,
              already_applied: false,
              head_oid: "expected-head",
              merge_commit_sha: "merge-sha"
            }} = Client.merge_pull_request("github:pr:45", "expected-head")
  end

  test "rejects a merge when the live pull request head changed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      send(test_pid, {:github_merge_request, method, path})
      github_response(200, %{"merged" => false, "head" => %{"sha" => "new-head"}})
    end)

    assert {:conflict,
            %{
              issue_id: "github:pr:46",
              expected_head_oid: "stale-head",
              current_head_oid: "new-head"
            }} = Client.merge_pull_request("github:pr:46", "stale-head")

    refute_receive {:github_merge_request, :put, _}, 50
  end

  test "creates a transition comment once using its journal marker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    marker = "<!-- sym-transition:transition-47 -->"
    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      json = Keyword.get(opts, :json)
      send(test_pid, {:github_comment_request, method, path, json})

      case {method, path} do
        {:get, "/repos/studiojin-dev/myven/issues/47/comments"} ->
          github_response(200, [])

        {:post, "/repos/studiojin-dev/myven/issues/47/comments"} ->
          assert json == %{body: "상태를 전이했습니다.\n\n#{marker}"}
          github_response(201, %{"id" => 1, "body" => json.body})
      end
    end)

    assert :applied = Client.create_comment_once("github:issue:47", "상태를 전이했습니다.", marker)
  end

  test "skips an already-applied transition comment marker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    marker = "<!-- sym-transition:transition-48 -->"
    test_pid = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      send(test_pid, {:github_comment_request, method, path})
      github_response(200, [%{"id" => 1, "body" => "기존 댓글\n\n#{marker}"}])
    end)

    assert :already_applied = Client.create_comment_once("github:pr:48", "중복되면 안 됩니다.", marker)
    refute_receive {:github_comment_request, :post, _}, 50
  end

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
    assert issue.metadata.physical_state == "open"
  end

  test "preserves explicit terminal labels on closed GitHub issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    for {number, label, state} <- [
          {51, "sym:done", "Done"},
          {52, "sym:canceled", "Canceled"},
          {53, "sym:duplicate", "Duplicate"}
        ] do
      assert {:ok, issue} =
               Client.normalize_issue_for_test(raw_issue(number, "Terminal #{state}", "", [%{"name" => label}], "closed"))

      assert issue.state == state
    end
  end

  test "normalizes a closed nonterminal GitHub issue as Canceled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert {:ok, issue} =
             Client.normalize_issue_for_test(raw_issue(54, "Closed without terminal intent", "", [%{"name" => "sym:review"}], "closed"))

    assert issue.state == "Canceled"
  end

  test "normalizes a closed pull request without a merge as Canceled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue =
      55
      |> raw_pull_request_issue([%{"name" => "sym:review"}])
      |> Map.put("state", "closed")

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/55", github_response(200, issue)},
      {:get, "/repos/studiojin-dev/myven/pulls/55", github_response(200, %{"merged" => false})}
    ])

    assert {:ok, [%{state: "Canceled"}]} = Client.fetch_issue_states_by_ids(["github:pr:55"])
    assert_github_responses_consumed()
  end

  test "normalizes a merged pull request as Done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue =
      56
      |> raw_pull_request_issue([%{"name" => "sym:review"}])
      |> Map.put("state", "closed")

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/56", github_response(200, issue)},
      {:get, "/repos/studiojin-dev/myven/pulls/56", github_response(200, %{"merged" => true})}
    ])

    assert {:ok, [%{state: "Done", metadata: %{physical_state: "closed", merged: true}}]} =
             Client.fetch_issue_states_by_ids(["github:pr:56"])

    assert_github_responses_consumed()
  end

  test "reports an untracked GitHub pull request as missing canonical state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue = raw_pull_request_issue(57, [])

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/57", github_response(200, issue)},
      {:get, "/repos/studiojin-dev/myven/pulls/57", github_response(200, %{"merged" => false})}
    ])

    assert {:error, :missing_canonical_state} = Client.fetch_issue_states_by_ids(["github:pr:57"])
    assert_github_responses_consumed()
  end

  test "preserves ambiguous GitHub canonical state labels during direct lookup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue = raw_pull_request_issue(59, [%{"name" => "sym:review"}, %{"name" => "sym:reviewing"}])

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/59", github_response(200, issue)},
      {:get, "/repos/studiojin-dev/myven/pulls/59", github_response(200, %{"merged" => false})}
    ])

    assert {:error, {:ambiguous_state_labels, states}} = Client.fetch_issue_states_by_ids(["github:pr:59"])
    assert Enum.sort(states) == ["Review", "Reviewing"]
    assert_github_responses_consumed()
  end

  test "continues to skip ambiguous GitHub candidates during polling" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    ambiguous_issue = %{
      "number" => 60,
      "title" => "Ambiguous candidate",
      "body" => "Two canonical labels",
      "state" => "open",
      "html_url" => "https://github.com/studiojin-dev/myven/pull/60",
      "pull_request" => %{"url" => "https://api.github.com/repos/studiojin-dev/myven/pulls/60"},
      "labels" => [%{"name" => "sym:review"}, %{"name" => "sym:reviewing"}]
    }

    stub_github_requests(self(), [
      {:get, "/search/issues", github_response(200, %{"items" => [ambiguous_issue]})}
    ])

    assert {:ok, []} = Client.fetch_issues_by_states(["Review"])
    assert_github_responses_consumed()
  end

  test "fails closed when pull request detail cannot provide the live head" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    issue = raw_pull_request_issue(58, [%{"name" => "sym:reviewing"}])

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/58", github_response(200, issue)},
      {:get, "/repos/studiojin-dev/myven/pulls/58", github_response(503, %{"message" => "unavailable"})}
    ])

    assert {:error, {:github_api_status, 503, %{"message" => "unavailable"}}} =
             Client.fetch_issue_states_by_ids(["github:pr:58"])

    assert_github_responses_consumed()
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
        {:get, "/repos/studiojin-dev/myven/issues/37/sub_issues"} ->
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/issues/37/parent"} ->
          github_response(404, %{"message" => "Not Found"})

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

  test "creates only the first split pull request for a sequential planned GitHub issue" do
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
        {:get, "/repos/studiojin-dev/myven/issues/84/sub_issues"} ->
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/issues/84/parent"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/issues/84/comments"} ->
          assert params == %{per_page: 100}
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/pulls"} ->
          assert params in [
                   %{state: "open", head: "studiojin-dev:symphony/_84-pr1", per_page: 1},
                   %{state: "all", head: "studiojin-dev:symphony/_84-pr1", per_page: 1},
                   %{state: "open", head: "studiojin-dev:symphony/_84-feature", per_page: 1}
                 ]

          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_84-feature"} ->
          feature_fetch_count = Process.get(:github_client_test_feature_84_fetch_count, 0) + 1
          Process.put(:github_client_test_feature_84_fetch_count, feature_fetch_count)

          if feature_fetch_count == 1 do
            github_response(404, %{"message" => "Not Found"})
          else
            github_response(200, %{"object" => %{"sha" => "feature-sha"}})
          end

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_84-pr1"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/main"} ->
          github_response(200, %{"object" => %{"sha" => "base-sha"}})

        {:get, "/repos/studiojin-dev/myven/git/commits/" <> sha} when sha in ["base-sha", "feature-sha"] ->
          github_response(200, %{"tree" => %{"sha" => "tree-sha"}})

        {:post, "/repos/studiojin-dev/myven/git/commits"} ->
          commit_count = Process.get(:github_client_test_84_commit_count, 0) + 1
          Process.put(:github_client_test_84_commit_count, commit_count)
          github_response(201, %{"sha" => if(commit_count == 1, do: "feature-sha", else: "child-sha")})

        {:post, "/repos/studiojin-dev/myven/git/refs"} ->
          assert json in [
                   %{ref: "refs/heads/symphony/_84-feature", sha: "feature-sha"},
                   %{ref: "refs/heads/symphony/_84-pr1", sha: "child-sha"}
                 ]

          github_response(201, %{"ref" => json.ref, "object" => %{"sha" => json.sha}})

        {:post, "/repos/studiojin-dev/myven/pulls"} ->
          pull_order = Process.get(:github_client_test_84_pull_order, [])
          Process.put(:github_client_test_84_pull_order, [json.head | pull_order])

          case json.head do
            "symphony/_84-pr1" ->
              assert json.base == "symphony/_84-feature"
              assert json.title == "Issue #84 PR1: 사용자 비밀번호 재설정 흐름 완성"
              assert json.body =~ "Refs #84"
              assert json.body =~ "병합 대상: `symphony/_84-feature` feature 브랜치"
              refute json.body =~ "Closes #84"
              assert json.body =~ "### PR1: 사용자 비밀번호 재설정 흐름 완성"
              assert json.body =~ "로그인/회원가입 링크와 Mailpit E2E를 추가한다."
              assert json.body =~ "- PR2: operator 비밀번호 찾기 상태 조회"
              refute json.body =~ "operator 목록과 API를 추가한다."

              github_response(201, %{"number" => 90})

            "symphony/_84-feature" ->
              assert json.base == "main"
              assert json.title == "Issue #84: 비밀번호 재설정 흐름 완성 통합"
              assert json.body =~ "Closes #84"
              assert json.body =~ "`sym:waiting` 상태로 유지"
              assert json.body =~ "implementation/review/rework/merge lane"
              assert json.body =~ "- PR1: 사용자 비밀번호 재설정 흐름 완성"
              assert json.body =~ "- PR2: operator 비밀번호 찾기 상태 조회"

              github_response(201, %{"number" => 89})
          end

        {:get, "/repos/studiojin-dev/myven/issues/" <> pull_number_text} ->
          pull_number = String.to_integer(pull_number_text)
          issue_fetch_count = Process.get({:github_client_test_issue_fetch_count, pull_number}, 0) + 1
          Process.put({:github_client_test_issue_fetch_count, pull_number}, issue_fetch_count)

          labels =
            if issue_fetch_count == 1 do
              []
            else
              label =
                case pull_number do
                  89 -> "sym:waiting"
                  90 -> "sym:planned"
                end

              [%{"name" => label}]
            end

          github_response(200, raw_pull_request_issue(pull_number, labels))

        {:get, "/repos/studiojin-dev/myven/labels/" <> encoded_label} ->
          github_response(200, %{"name" => URI.decode_www_form(encoded_label)})

        {:post, "/repos/studiojin-dev/myven/issues/" <> label_path} ->
          assert String.ends_with?(label_path, "/labels")
          assert json in [%{labels: ["sym:planned"]}, %{labels: ["sym:waiting"]}]
          github_response(200, Enum.map(json.labels, &%{"name" => &1}))

        {:get, "/repos/studiojin-dev/myven/pulls/90"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_84-pr1"}, "merged" => false})

        {:get, "/repos/studiojin-dev/myven/pulls/89"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_84-feature"}, "merged" => false})
      end
    end)

    issue = %Issue{
      id: "github:issue:84",
      identifier: "#84",
      title: "비밀번호 재설정 흐름 완성",
      description: """
      ## PR 진행 계획

      ### PR1: 사용자 비밀번호 재설정 흐름 완성

      로그인/회원가입 링크와 Mailpit E2E를 추가한다.

      ### PR2: operator 비밀번호 찾기 상태 조회

      operator 목록과 API를 추가한다.
      """,
      state: "Planned",
      kind: :issue,
      url: "https://github.com/studiojin-dev/myven/issues/84"
    }

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(issue)
    assert pull_request.id == "github:pr:90"
    assert pull_request.branch_name == "symphony/_84-pr1"

    assert Enum.reverse(Process.get(:github_client_test_84_pull_order, [])) == [
             "symphony/_84-feature",
             "symphony/_84-pr1"
           ]

    refute_receive {:github_request, :get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_84-pr2", _, _}
    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_84-feature", base: "main"}}
  end

  test "creates the requested next split child pull request while integration PR waits" do
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
        {:get, "/repos/studiojin-dev/myven/issues/245/sub_issues"} ->
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/issues/245/parent"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/issues/245/comments"} ->
          assert params == %{per_page: 100}
          github_response(200, [%{"body" => "pr2 구현 시작."}])

        {:get, "/repos/studiojin-dev/myven/pulls"} ->
          case params do
            %{state: "all", head: "studiojin-dev:symphony/_245-pr2", per_page: 1} ->
              github_response(200, [])

            %{state: "open", head: "studiojin-dev:symphony/_245-feature", per_page: 1} ->
              github_response(200, [%{"number" => 247, "state" => "open"}])

            %{state: "open", head: "studiojin-dev:symphony/_245-pr2", per_page: 1} ->
              github_response(200, [])
          end

        {:get, "/repos/studiojin-dev/myven/issues/247"} ->
          github_response(200, raw_pull_request_issue(247, [%{"name" => "sym:waiting"}]))

        {:get, "/repos/studiojin-dev/myven/pulls/247"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_245-feature"}, "merged" => false})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_245-feature"} ->
          github_response(200, %{"object" => %{"sha" => "feature-sha"}})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_245-pr2"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/commits/feature-sha"} ->
          github_response(200, %{"tree" => %{"sha" => "tree-sha"}})

        {:post, "/repos/studiojin-dev/myven/git/commits"} ->
          github_response(201, %{"sha" => "child-sha"})

        {:post, "/repos/studiojin-dev/myven/git/refs"} ->
          assert json == %{ref: "refs/heads/symphony/_245-pr2", sha: "child-sha"}
          github_response(201, %{"ref" => json.ref, "object" => %{"sha" => json.sha}})

        {:post, "/repos/studiojin-dev/myven/pulls"} ->
          assert json.head == "symphony/_245-pr2"
          assert json.base == "symphony/_245-feature"
          assert json.title == "Issue #245 PR2: Terraform-managed Lambda cron과 staging 배포"
          assert json.body =~ "Refs #245"
          refute json.body =~ "Closes #245"
          github_response(201, %{"number" => 248})

        {:get, "/repos/studiojin-dev/myven/issues/248"} ->
          issue_fetch_count = Process.get(:github_client_test_248_fetch_count, 0) + 1
          Process.put(:github_client_test_248_fetch_count, issue_fetch_count)

          labels =
            if issue_fetch_count == 1 do
              []
            else
              [%{"name" => "sym:planned"}]
            end

          github_response(200, raw_pull_request_issue(248, labels))

        {:get, "/repos/studiojin-dev/myven/labels/sym%3Aplanned"} ->
          github_response(200, %{"name" => "sym:planned"})

        {:post, "/repos/studiojin-dev/myven/issues/248/labels"} ->
          assert json == %{labels: ["sym:planned"]}
          github_response(200, [%{"name" => "sym:planned"}])

        {:get, "/repos/studiojin-dev/myven/pulls/248"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_245-pr2"}, "merged" => false})
      end
    end)

    issue = %Issue{
      id: "github:issue:245",
      identifier: "#245",
      title: "analytics aggregation 워크플로 부활",
      description: """
      ## PR 진행 계획

      ### PR1: web-api internal drain endpoint와 bounded 처리 계약

      endpoint를 추가한다.

      ### PR2: Terraform-managed Lambda cron과 staging 배포

      Lambda cron을 추가한다.

      ### PR3: production 적용과 운영 문서화

      production에 적용한다.
      """,
      state: "Planned",
      kind: :issue,
      url: "https://github.com/studiojin-dev/myven/issues/245"
    }

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(issue)
    assert pull_request.id == "github:pr:248"
    assert pull_request.branch_name == "symphony/_245-pr2"

    refute_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_245-feature"}}
    refute_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_245-pr1"}}
  end

  test "creates all split pull requests when the planned GitHub issue explicitly marks parallel execution" do
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
        {:get, "/repos/studiojin-dev/myven/issues/91/sub_issues"} ->
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/issues/91/parent"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/pulls"} ->
          assert params in [
                   %{state: "open", head: "studiojin-dev:symphony/_91-pr1", per_page: 1},
                   %{state: "open", head: "studiojin-dev:symphony/_91-pr2", per_page: 1},
                   %{state: "open", head: "studiojin-dev:symphony/_91-feature", per_page: 1}
                 ]

          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_91-feature"} ->
          feature_fetch_count = Process.get(:github_client_test_feature_91_fetch_count, 0) + 1
          Process.put(:github_client_test_feature_91_fetch_count, feature_fetch_count)

          if feature_fetch_count == 1 do
            github_response(404, %{"message" => "Not Found"})
          else
            github_response(200, %{"object" => %{"sha" => "feature-sha"}})
          end

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_91-pr1"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_91-pr2"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/main"} ->
          github_response(200, %{"object" => %{"sha" => "base-sha"}})

        {:get, "/repos/studiojin-dev/myven/git/commits/" <> sha} when sha in ["base-sha", "feature-sha"] ->
          github_response(200, %{"tree" => %{"sha" => "tree-sha"}})

        {:post, "/repos/studiojin-dev/myven/git/commits"} ->
          commit_count = Process.get(:github_client_test_91_commit_count, 0) + 1
          Process.put(:github_client_test_91_commit_count, commit_count)

          sha =
            case commit_count do
              1 -> "feature-sha"
              2 -> "child-1-sha"
              _ -> "child-#{commit_count - 1}-sha"
            end

          github_response(201, %{"sha" => sha})

        {:post, "/repos/studiojin-dev/myven/git/refs"} ->
          assert json in [
                   %{ref: "refs/heads/symphony/_91-feature", sha: "feature-sha"},
                   %{ref: "refs/heads/symphony/_91-pr1", sha: "child-1-sha"},
                   %{ref: "refs/heads/symphony/_91-pr2", sha: "child-2-sha"}
                 ]

          github_response(201, %{"ref" => json.ref, "object" => %{"sha" => json.sha}})

        {:post, "/repos/studiojin-dev/myven/pulls"} ->
          pull_order = Process.get(:github_client_test_91_pull_order, [])
          Process.put(:github_client_test_91_pull_order, [json.head | pull_order])

          pull_number =
            case json.head do
              "symphony/_91-pr1" ->
                assert json.base == "symphony/_91-feature"
                assert json.title == "Issue #91 PR1: 독립 API 테스트"
                91

              "symphony/_91-pr2" ->
                assert json.base == "symphony/_91-feature"
                assert json.title == "Issue #91 PR2: 독립 UI 스모크"
                92

              "symphony/_91-feature" ->
                assert json.base == "main"
                assert json.title == "Issue #91: 병렬 분할 작업 통합"
                assert json.body =~ "Closes #91"
                assert json.body =~ "`sym:waiting` 상태로 유지"
                assert json.body =~ "implementation/review/rework/merge lane"
                assert json.body =~ "- PR1: 독립 API 테스트"
                assert json.body =~ "- PR2: 독립 UI 스모크"
                90
            end

          if json.head != "symphony/_91-feature" do
            assert json.body =~ "Refs #91"
            assert json.body =~ "병합 대상: `symphony/_91-feature` feature 브랜치"
            refute json.body =~ "Closes #91"
          end

          github_response(201, %{"number" => pull_number})

        {:get, "/repos/studiojin-dev/myven/issues/" <> pull_number_text} ->
          pull_number = String.to_integer(pull_number_text)
          issue_fetch_count = Process.get({:github_client_test_91_issue_fetch_count, pull_number}, 0) + 1
          Process.put({:github_client_test_91_issue_fetch_count, pull_number}, issue_fetch_count)

          labels =
            if issue_fetch_count == 1 do
              []
            else
              label =
                case pull_number do
                  90 -> "sym:waiting"
                  91 -> "sym:planned"
                  92 -> "sym:planned"
                end

              [%{"name" => label}]
            end

          github_response(200, raw_pull_request_issue(pull_number, labels))

        {:get, "/repos/studiojin-dev/myven/labels/" <> encoded_label} ->
          github_response(200, %{"name" => URI.decode_www_form(encoded_label)})

        {:delete, "/repos/studiojin-dev/myven/issues/" <> label_path} ->
          assert String.ends_with?(label_path, "/labels/sym%3Aplanned")
          github_response(200, %{})

        {:post, "/repos/studiojin-dev/myven/issues/" <> pull_label_path} ->
          assert String.ends_with?(pull_label_path, "/labels")
          assert json in [%{labels: ["sym:planned"]}, %{labels: ["sym:waiting"]}]
          github_response(200, Enum.map(json.labels, &%{"name" => &1}))

        {:get, "/repos/studiojin-dev/myven/pulls/90"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_91-feature"}, "merged" => false})

        {:get, "/repos/studiojin-dev/myven/pulls/91"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_91-pr1"}, "merged" => false})

        {:get, "/repos/studiojin-dev/myven/pulls/92"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_91-pr2"}, "merged" => false})
      end
    end)

    issue = %Issue{
      id: "github:issue:91",
      identifier: "#91",
      title: "병렬 분할 작업",
      description: """
      PR 진행 방식: 병렬

      ### PR1: 독립 API 테스트

      API 테스트를 추가한다.

      ### PR2: 독립 UI 스모크

      UI 스모크를 추가한다.
      """,
      state: "Planned",
      kind: :issue,
      url: "https://github.com/studiojin-dev/myven/issues/91"
    }

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(issue)
    assert pull_request.id == "github:pr:91"

    assert Enum.reverse(Process.get(:github_client_test_91_pull_order, [])) == [
             "symphony/_91-feature",
             "symphony/_91-pr1",
             "symphony/_91-pr2"
           ]

    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_91-pr1"}}
    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_91-pr2"}}
    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/pulls", nil, %{head: "symphony/_91-feature", base: "main"}}
  end

  test "delegates parent issue pull request creation to the first planned sub-issue" do
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
        {:get, "/repos/studiojin-dev/myven/issues/122/sub_issues"} ->
          github_response(200, [
            raw_issue(123, "Sub issue one", "Child implementation", [%{"name" => "sym:planned"}]),
            raw_issue(124, "Sub issue two", "Later child", [%{"name" => "sym:todo"}])
          ])

        {:get, "/repos/studiojin-dev/myven/pulls"} ->
          assert params == %{state: "open", head: "studiojin-dev:symphony/_123", per_page: 1}
          github_response(200, [])

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/symphony/_123"} ->
          github_response(404, %{"message" => "Not Found"})

        {:get, "/repos/studiojin-dev/myven/git/ref/heads/main"} ->
          github_response(200, %{"object" => %{"sha" => "base-sha"}})

        {:get, "/repos/studiojin-dev/myven/git/commits/base-sha"} ->
          github_response(200, %{"tree" => %{"sha" => "tree-sha"}})

        {:post, "/repos/studiojin-dev/myven/git/commits"} ->
          assert json.message == "chore: prepare issue #123 implementation PR"
          github_response(201, %{"sha" => "empty-sha"})

        {:post, "/repos/studiojin-dev/myven/git/refs"} ->
          assert json == %{ref: "refs/heads/symphony/_123", sha: "empty-sha"}
          github_response(201, %{"ref" => "refs/heads/symphony/_123", "object" => %{"sha" => "empty-sha"}})

        {:post, "/repos/studiojin-dev/myven/pulls"} ->
          assert json.head == "symphony/_123"
          assert json.title == "Issue #123: Sub issue one"
          assert json.body =~ "Closes #123"
          assert json.body =~ "Refs #122"
          refute json.body =~ "Closes #122"
          github_response(201, %{"number" => 130})

        {:get, "/repos/studiojin-dev/myven/issues/130"} ->
          github_response(200, raw_pull_request_issue(130, [%{"name" => "sym:planned"}]))

        {:get, "/repos/studiojin-dev/myven/labels/sym%3Aplanned"} ->
          github_response(200, %{"name" => "sym:planned"})

        {:delete, "/repos/studiojin-dev/myven/issues/130/labels/sym%3Aplanned"} ->
          github_response(200, %{})

        {:post, "/repos/studiojin-dev/myven/issues/130/labels"} ->
          github_response(200, [%{"name" => "sym:planned"}])

        {:get, "/repos/studiojin-dev/myven/pulls/130"} ->
          github_response(200, %{"head" => %{"ref" => "symphony/_123"}, "merged" => false})
      end
    end)

    issue = %Issue{
      id: "github:issue:122",
      identifier: "#122",
      title: "Parent performance work",
      description: "Coordinate sub-issues.",
      state: "Planned",
      kind: :issue,
      url: "https://github.com/studiojin-dev/myven/issues/122"
    }

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(issue)
    assert pull_request.id == "github:pr:130"
    assert pull_request.branch_name == "symphony/_123"

    refute_receive {:github_request, :get, "/repos/studiojin-dev/myven/pulls", %{head: "studiojin-dev:symphony/_122"}, _}
  end

  test "does not create a parent pull request when no sub-issue is planned" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/122/sub_issues",
       github_response(200, [
         raw_issue(123, "Sub issue one", "Child implementation", [%{"name" => "sym:human-review"}]),
         raw_issue(124, "Sub issue two", "Later child", [%{"name" => "sym:todo"}])
       ])}
    ])

    issue = %Issue{
      id: "github:issue:122",
      identifier: "#122",
      title: "Parent performance work",
      description: "Coordinate sub-issues.",
      state: "Planned",
      kind: :issue
    }

    assert {:error, {:github_no_planned_sub_issue, 122}} = Client.create_pull_request_for_issue(issue)
    assert_github_responses_consumed()
  end

  test "syncs labeled issue webhook by keeping one Symphony state label" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/42/labels", github_response(200, [%{"name" => "sym:todo"}, %{"name" => "sym:planned"}, %{"name" => "enhancement"}])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Aplanned", github_response(200, %{"name" => "sym:planned"})},
      {:delete, "/repos/studiojin-dev/myven/issues/42/labels/sym%3Atodo", github_response(200, %{})},
      {:get, "/repos/studiojin-dev/myven/issues/42", github_response(200, %{"state" => "open", "state_reason" => nil})}
    ])

    assert :ok =
             Client.sync_webhook_state("issues", "labeled", %{
               "issue" => %{"number" => 42},
               "label" => %{"name" => "sym:planned"}
             })

    assert_receive {:github_request, :get, "/repos/studiojin-dev/myven/issues/42/labels", %{per_page: 100}, nil}
    assert_receive {:github_request, :get, "/repos/studiojin-dev/myven/labels/sym%3Aplanned", nil, nil}
    assert_receive {:github_request, :delete, "/repos/studiojin-dev/myven/issues/42/labels/sym%3Atodo", nil, nil}
    assert_receive {:github_request, :get, "/repos/studiojin-dev/myven/issues/42", nil, nil}
    refute_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/42/labels", _, _}
    assert_github_responses_consumed()
  end

  test "queues a Codex inline review comment on an unlabeled pull request for rework" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    raw_pr = raw_pull_request_issue(90, [])

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/90", github_response(200, raw_pr)},
      {:get, "/repos/studiojin-dev/myven/issues/90", github_response(200, raw_pr)},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Arework", github_response(200, %{"name" => "sym:rework"})},
      {:post, "/repos/studiojin-dev/myven/issues/90/labels", github_response(200, [%{"name" => "sym:rework"}])}
    ])

    assert :ok =
             Client.queue_rework_from_review_comment("pull_request_review_comment", "created", %{
               "pull_request" => %{"number" => 90},
               "comment" => %{"user" => %{"login" => "chatgpt-codex-connector"}}
             })

    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/90/labels", nil, %{labels: ["sym:rework"]}}
    assert_github_responses_consumed()
  end

  test "does not queue inline comments from other review bots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert :ok =
             Client.queue_rework_from_review_comment("pull_request_review_comment", "created", %{
               "pull_request" => %{"number" => 91},
               "comment" => %{"user" => %{"login" => "dependabot[bot]"}}
             })

    refute_receive {:github_request, _, _, _, _}
  end

  test "ignores stale labeled issue webhook when payload label is no longer present" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/43/labels", github_response(200, [%{"name" => "sym:todo"}])}
    ])

    assert :ok =
             Client.sync_webhook_state("issues", "labeled", %{
               "issue" => %{"number" => 43},
               "label" => %{"name" => "sym:planned"}
             })

    assert_receive {:github_request, :get, "/repos/studiojin-dev/myven/issues/43/labels", %{per_page: 100}, nil}
    assert_github_responses_consumed()
  end

  test "syncs terminal and reopen issue state from labeled issue webhooks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    for {number, label, issue_state, issue_reason, expected_patch} <- [
          {44, "sym:done", "open", nil, %{state: "closed", state_reason: "completed"}},
          {45, "sym:canceled", "open", nil, %{state: "closed", state_reason: "not_planned"}},
          {46, "sym:duplicate", "open", nil, %{state: "closed", state_reason: "not_planned"}},
          {47, "sym:planned", "closed", "completed", %{state: "open"}}
        ] do
      patch_path = "/repos/studiojin-dev/myven/issues/#{number}"

      responses =
        [
          {:get, "/repos/studiojin-dev/myven/issues/#{number}/labels", github_response(200, [%{"name" => label}])},
          {:get, "/repos/studiojin-dev/myven/labels/#{URI.encode_www_form(label)}", github_response(200, %{"name" => label})},
          {:get, patch_path, github_response(200, %{"state" => issue_state, "state_reason" => issue_reason})}
        ] ++
          if label in ["sym:done", "sym:canceled", "sym:duplicate"] do
            [
              {:get, "/repos/studiojin-dev/myven/issues/#{number}/sub_issues", github_response(200, [])},
              {:patch, patch_path, github_response(200, %{})},
              {:get, "/repos/studiojin-dev/myven/issues/#{number}/parent", github_response(404, %{"message" => "Not Found"})}
            ]
          else
            [
              {:patch, patch_path, github_response(200, %{})}
            ]
          end

      stub_github_requests(self(), responses)

      assert :ok =
               Client.sync_webhook_state("issues", "labeled", %{
                 "issue" => %{"number" => number},
                 "label" => %{"name" => label}
               })

      assert_receive {:github_request, :patch, ^patch_path, nil, ^expected_patch}
      assert_github_responses_consumed()
    end
  end

  test "keeps parent issue in human review when terminal label arrives before all sub-issues are terminal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Adone", github_response(200, %{"name" => "sym:done"})},
      {:get, "/repos/studiojin-dev/myven/issues/122", github_response(200, %{"state" => "closed", "state_reason" => "completed"})},
      {:get, "/repos/studiojin-dev/myven/issues/122/sub_issues",
       github_response(200, [
         raw_issue(123, "Done child", "Done", [%{"name" => "sym:done"}], "closed"),
         raw_issue(124, "Planned child", "Not done", [%{"name" => "sym:planned"}])
       ])},
      {:get, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Ahuman-review", github_response(200, %{"name" => "sym:human-review"})},
      {:delete, "/repos/studiojin-dev/myven/issues/122/labels/sym%3Adone", github_response(200, %{})},
      {:post, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:human-review"}])},
      {:patch, "/repos/studiojin-dev/myven/issues/122", github_response(200, %{})},
      {:get, "/repos/studiojin-dev/myven/issues/122/parent", github_response(404, %{"message" => "Not Found"})}
    ])

    assert :ok =
             Client.sync_webhook_state("issues", "labeled", %{
               "issue" => %{"number" => 122},
               "label" => %{"name" => "sym:done"}
             })

    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/122/labels", nil, %{labels: ["sym:human-review"]}}
    assert_receive {:github_request, :patch, "/repos/studiojin-dev/myven/issues/122", nil, %{state: "open"}}
    assert_github_responses_consumed()
  end

  test "closed child issue webhook marks parent done only after all sub-issues are terminal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/123/labels", github_response(200, [])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Adone", github_response(200, %{"name" => "sym:done"})},
      {:post, "/repos/studiojin-dev/myven/issues/123/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:get, "/repos/studiojin-dev/myven/issues/123", github_response(200, %{"state" => "open", "state_reason" => nil})},
      {:get, "/repos/studiojin-dev/myven/issues/123/sub_issues", github_response(200, [])},
      {:patch, "/repos/studiojin-dev/myven/issues/123", github_response(200, %{})},
      {:get, "/repos/studiojin-dev/myven/issues/123/parent", github_response(200, %{"number" => 122})},
      {:get, "/repos/studiojin-dev/myven/issues/122", github_response(200, %{"state" => "open", "state_reason" => nil})},
      {:get, "/repos/studiojin-dev/myven/issues/122/sub_issues",
       github_response(200, [
         raw_issue(123, "Done child", "Done", [%{"name" => "sym:done"}], "closed"),
         raw_issue(124, "Canceled child", "Canceled", [%{"name" => "sym:canceled"}], "closed")
       ])},
      {:get, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:human-review"}])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Adone", github_response(200, %{"name" => "sym:done"})},
      {:delete, "/repos/studiojin-dev/myven/issues/122/labels/sym%3Ahuman-review", github_response(200, %{})},
      {:post, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:done"}])},
      {:patch, "/repos/studiojin-dev/myven/issues/122", github_response(200, %{})}
    ])

    assert :ok =
             Client.sync_webhook_state("issues", "closed", %{
               "issue" => %{"number" => 123, "state_reason" => "completed"}
             })

    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/123/labels", nil, %{labels: ["sym:done"]}}
    assert_receive {:github_request, :patch, "/repos/studiojin-dev/myven/issues/123", nil, %{state: "closed", state_reason: "completed"}}
    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/122/labels", nil, %{labels: ["sym:done"]}}
    assert_receive {:github_request, :patch, "/repos/studiojin-dev/myven/issues/122", nil, %{state: "closed", state_reason: "completed"}}
    assert_github_responses_consumed()
  end

  test "direct done state update for parent issue is guarded by incomplete sub-issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    stub_github_requests(self(), [
      {:get, "/repos/studiojin-dev/myven/issues/122",
       github_response(200, %{
         "number" => 122,
         "labels" => [%{"name" => "sym:human-review"}],
         "state" => "closed"
       })},
      {:get, "/repos/studiojin-dev/myven/issues/122/sub_issues",
       github_response(200, [
         raw_issue(123, "Done child", "Done", [%{"name" => "sym:done"}], "closed"),
         raw_issue(124, "Planned child", "Not done", [%{"name" => "sym:planned"}])
       ])},
      {:get, "/repos/studiojin-dev/myven/labels/sym%3Ahuman-review", github_response(200, %{"name" => "sym:human-review"})},
      {:delete, "/repos/studiojin-dev/myven/issues/122/labels/sym%3Ahuman-review", github_response(200, %{})},
      {:post, "/repos/studiojin-dev/myven/issues/122/labels", github_response(200, [%{"name" => "sym:human-review"}])},
      {:patch, "/repos/studiojin-dev/myven/issues/122", github_response(200, %{})}
    ])

    assert :ok = Client.update_issue_state("github:issue:122", "Done")
    assert_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/122/labels", nil, %{labels: ["sym:human-review"]}}
    assert_receive {:github_request, :patch, "/repos/studiojin-dev/myven/issues/122", nil, %{state: "open"}}
    refute_receive {:github_request, :post, "/repos/studiojin-dev/myven/issues/122/labels", nil, %{labels: ["sym:done"]}}
    assert_github_responses_consumed()
  end

  test "syncs merged and closed pull request webhooks to terminal state labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    for {number, merged?, existing_labels, target_label, removed_label} <- [
          {48, true, [%{"name" => "sym:merging"}], "sym:done", "sym:merging"},
          {49, false, [], "sym:canceled", nil}
        ] do
      post_path = "/repos/studiojin-dev/myven/issues/#{number}/labels"

      responses =
        [
          {:get, "/repos/studiojin-dev/myven/issues/#{number}/labels", github_response(200, existing_labels)},
          {:get, "/repos/studiojin-dev/myven/labels/#{URI.encode_www_form(target_label)}", github_response(200, %{"name" => target_label})}
        ] ++
          if removed_label do
            [
              {:delete, "/repos/studiojin-dev/myven/issues/#{number}/labels/#{URI.encode_www_form(removed_label)}", github_response(200, %{})}
            ]
          else
            []
          end ++
          [{:post, post_path, github_response(200, [%{"name" => target_label}])}]

      stub_github_requests(self(), responses)

      assert :ok =
               Client.sync_webhook_state("pull_request", "closed", %{
                 "pull_request" => %{"number" => number, "merged" => merged?}
               })

      assert_receive {:github_request, :post, ^post_path, nil, %{labels: [^target_label]}}
      assert_github_responses_consumed()
    end
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

  test "rejects GitHub issues with ambiguous Symphony state labels during direct normalization" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "studiojin-dev",
      tracker_repo: "myven",
      tracker_project_slug: nil
    )

    assert {:error, {:ambiguous_state_labels, states}} =
             Client.normalize_issue_for_test(%{
               "number" => 9,
               "title" => "Conflicting state",
               "body" => "Two state labels",
               "state" => "open",
               "html_url" => "https://github.com/studiojin-dev/myven/issues/9",
               "labels" => [%{"name" => "sym:review"}, %{"name" => "sym:reviewing"}]
             })

    assert Enum.sort(states) == ["Review", "Reviewing"]
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

  defp stub_github_requests(test_pid, responses) do
    Process.put(:github_client_test_responses, responses)

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      params = Keyword.get(opts, :params)
      json = Keyword.get(opts, :json)

      send(test_pid, {:github_request, method, path, params, json})

      case Process.get(:github_client_test_responses, []) do
        [{^method, ^path, response} | rest] ->
          Process.put(:github_client_test_responses, rest)
          response

        [{expected_method, expected_path, _response} | _rest] ->
          raise "unexpected GitHub request #{inspect({method, path})}, expected #{inspect({expected_method, expected_path})}"

        [] ->
          raise "unexpected GitHub request #{inspect({method, path})}"
      end
    end)
  end

  defp assert_github_responses_consumed do
    assert Process.get(:github_client_test_responses, []) == []
  end

  defp raw_issue(number, title, body, labels, state \\ "open") do
    %{
      "number" => number,
      "title" => title,
      "body" => body,
      "state" => state,
      "html_url" => "https://github.com/studiojin-dev/myven/issues/#{number}",
      "labels" => labels,
      "created_at" => "2026-05-10T00:00:00Z",
      "updated_at" => "2026-05-10T00:00:00Z"
    }
  end

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
