defmodule SymphonyElixir.ForgejoClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Forgejo.{Adapter, Client}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), forgejo_config())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :forgejo_request_fun)
      Application.delete_env(:symphony_elixir, :forgejo_client_module)
    end)

    :ok
  end

  test "preflight accepts Forgejo v16 and uses token authentication" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :forgejo_request_fun, fn opts ->
      send(test_pid, {:request, opts})
      response(200, %{"version" => "16.0.1+gitea-1.25.0"})
    end)

    assert :ok = Client.preflight()
    assert_receive {:request, opts}
    assert Keyword.fetch!(opts, :url) == "https://forgejo.example/api/v1/version"
    assert {"Authorization", "token secret"} in Keyword.fetch!(opts, :headers)
  end

  test "preflight rejects any Forgejo major other than v16" do
    Application.put_env(:symphony_elixir, :forgejo_request_fun, fn _opts ->
      response(200, %{"version" => "17.2.0"})
    end)

    assert {:error, {:unsupported_forgejo_major, 17, 16}} = Client.preflight()
  end

  test "classifies state and request labels through the adapter seam" do
    assert {:state, "Reworking"} = Client.classify_managed_label("SYM:REWORKING")
    assert {:request, "Rework"} = Adapter.classify_managed_label("sym:request-rework")
    assert :unmanaged = Client.classify_managed_label("customer-facing")
  end

  test "normalizes same-repository pull requests and records parent labels" do
    raw =
      raw_pull(19, "abc123", [
        %{"id" => 3, "name" => "sym:review"},
        %{"id" => 9, "name" => "sym:parent-7"}
      ])

    assert {:ok, issue} = Client.normalize_issue_for_test(raw, :pull_request)
    assert issue.id == "forgejo:pr:19"
    assert issue.identifier == "Forgejo PR #19"
    assert issue.state == "Review"
    assert issue.branch_name == "symphony/_7"
    assert issue.metadata.head_oid == "abc123"
    assert issue.metadata.parent_number == 7
    assert issue.metadata.physical_state == "open"
  end

  test "normalizes a merged pull request as Done even if an older state label remains" do
    raw =
      raw_pull(20, "merged-head", [%{"id" => 3, "name" => "sym:review"}], %{
        "state" => "closed",
        "merged" => true
      })

    assert {:ok, issue} = Client.normalize_issue_for_test(raw, :pull_request)
    assert issue.state == "Done"
    assert issue.metadata.physical_state == "closed"
  end

  test "keeps a merged Merging pull in the state-manager path until sym:done is projected" do
    raw =
      raw_pull(20, "merged-head", [%{"id" => 3, "name" => "sym:merging"}], %{
        "state" => "closed",
        "merged" => true
      })

    assert {:ok, issue} = Client.normalize_issue_for_test(raw, :pull_request)
    assert issue.state == "Merging"
    assert issue.metadata.merged
  end

  test "normalizes closed active issues and unmerged pulls as Canceled while retaining terminal labels" do
    closed_issue =
      raw_issue(21, [%{"id" => 3, "name" => "sym:review"}])
      |> Map.put("state", "closed")

    closed_pull =
      raw_pull(22, "closed-head", [%{"id" => 3, "name" => "sym:review"}], %{
        "state" => "closed"
      })

    terminal_issue =
      raw_issue(23, [%{"id" => 7, "name" => "sym:done"}])
      |> Map.put("state", "closed")

    assert {:ok, %{state: "Canceled", labels: ["sym:review"]}} =
             Client.normalize_issue_for_test(closed_issue, :issue)

    assert {:ok, %{state: "Canceled", labels: ["sym:review"]}} =
             Client.normalize_issue_for_test(closed_pull, :pull_request)

    assert {:ok, %{state: "Done", labels: ["sym:done"]}} =
             Client.normalize_issue_for_test(terminal_issue, :issue)
  end

  test "rejects malformed or multiple Forgejo parent labels" do
    malformed =
      raw_issue(20, [
        %{"id" => 1, "name" => "sym:planned"},
        %{"id" => 2, "name" => "sym:parent-x"}
      ])

    assert {:error, {:invalid_forgejo_parent_labels, ["sym:parent-x"]}} =
             Client.normalize_issue_for_test(malformed, :issue)

    multiple =
      raw_issue(21, [
        %{"id" => 1, "name" => "sym:planned"},
        %{"id" => 2, "name" => "sym:parent-4"},
        %{"id" => 3, "name" => "sym:parent-5"}
      ])

    assert {:error, {:invalid_forgejo_parent_labels, ["sym:parent-4", "sym:parent-5"]}} =
             Client.normalize_issue_for_test(multiple, :issue)
  end

  test "unrelated malformed parent labels do not block another planned issue" do
    selected = %SymphonyElixir.Tracker.Issue{
      id: "forgejo:issue:30",
      identifier: "Forgejo #30",
      title: "Selected",
      state: "Planned",
      kind: :issue,
      labels: ["sym:planned"]
    }

    unrelated =
      raw_issue(99, [
        %{"id" => 1, "name" => "sym:planned"},
        %{"id" => 2, "name" => "sym:parent-x"}
      ])

    assert {:ok, ^selected, 30, nil} =
             Client.select_planned_issue_for_test(selected, 30, [unrelated])

    conflicting_child =
      raw_issue(31, [
        %{"id" => 1, "name" => "sym:planned"},
        %{"id" => 2, "name" => "sym:parent-30"},
        %{"id" => 3, "name" => "sym:parent-40"}
      ])

    assert {:error, {:invalid_forgejo_parent_labels, ["sym:parent-30", "sym:parent-40"]}} =
             Client.select_planned_issue_for_test(selected, 30, [unrelated, conflicting_child])
  end

  test "projects labels by numeric ID while preserving unmanaged labels" do
    issue = raw_issue(42, [%{"id" => 1, "name" => "bug"}, %{"id" => 2, "name" => "sym:planned"}])

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/42", response(200, issue)},
      {:get, "/api/v1/repos/acme/widgets/labels", response(200, [%{"id" => 7, "name" => "sym:review"}])},
      {:put, "/api/v1/repos/acme/widgets/issues/42/labels",
       fn opts ->
         assert Keyword.fetch!(opts, :json) == %{labels: [1, 7]}
         response(200, [])
       end},
      {:get, "/api/v1/repos/acme/widgets/issues/42/labels", response(200, [%{"id" => 1, "name" => "bug"}, %{"id" => 7, "name" => "sym:review"}])}
    ])

    assert {:applied, %{state: "Review", labels: ["bug", "sym:review"]}} =
             Client.apply_state_projection("forgejo:issue:42", "Planned", "Review")

    assert_requests_consumed()
  end

  test "repairs physical state even when the target state label is already applied" do
    issue = raw_issue(42, [%{"id" => 7, "name" => "sym:done"}])

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/42", response(200, issue)},
      {:get, "/api/v1/repos/acme/widgets/issues", response(200, [])},
      {:get, "/api/v1/repos/acme/widgets/labels", response(200, [%{"id" => 7, "name" => "sym:done"}])},
      {:patch, "/api/v1/repos/acme/widgets/issues/42", response(200, %{"state" => "closed"})},
      {:get, "/api/v1/repos/acme/widgets/issues/42", response(200, %{"state" => "closed"})}
    ])

    assert {:already_applied, %{state: "Done"}} =
             Client.apply_state_projection("forgejo:issue:42", "Done", "Done")

    assert_requests_consumed()
  end

  test "defers parent completion until every declared child is terminal" do
    parent = raw_issue(30, [%{"id" => 2, "name" => "sym:planned"}])

    child =
      raw_issue(31, [
        %{"id" => 3, "name" => "sym:planned"},
        %{"id" => 4, "name" => "sym:parent-30"}
      ])

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/30", response(200, parent)},
      {:get, "/api/v1/repos/acme/widgets/issues", response(200, [child])}
    ])

    assert {:conflict, %{reason: {:forgejo_parent_completion_deferred, 30}}} =
             Client.apply_state_projection("forgejo:issue:30", "Planned", "Done")

    assert_requests_consumed()
  end

  test "leaves parent completion to the journaled orchestrator transition" do
    child =
      raw_issue(31, [
        %{"id" => 7, "name" => "sym:done"},
        %{"id" => 9, "name" => "sym:parent-30"}
      ])
      |> Map.put("state", "closed")

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/31", response(200, child)},
      {:get, "/api/v1/repos/acme/widgets/issues", response(200, [])},
      {:get, "/api/v1/repos/acme/widgets/labels", response(200, [%{"id" => 7, "name" => "sym:done"}])}
    ])

    assert {:already_applied, %{state: "Done"}} =
             Client.apply_state_projection("forgejo:issue:31", "Done", "Done")

    assert_requests_consumed()
  end

  test "does not create a parent PR when its children contain no open Planned issue" do
    parent = %SymphonyElixir.Tracker.Issue{
      id: "forgejo:issue:30",
      identifier: "Forgejo #30",
      title: "Parent",
      state: "Planned",
      kind: :issue,
      labels: ["sym:planned"]
    }

    child =
      raw_issue(31, [
        %{"id" => 1, "name" => "sym:review"},
        %{"id" => 2, "name" => "sym:parent-30"}
      ])

    assert {:error, {:forgejo_no_planned_child_issue, 30}} =
             Client.select_planned_issue_for_test(parent, 30, [child])
  end

  test "rejects pull requests without explicit same-repository identity" do
    raw = raw_pull(19, "abc123", []) |> put_in(["head", "repo"], nil)

    assert {:error, :cross_repository_pull_request} =
             Client.normalize_issue_for_test(raw, :pull_request)
  end

  test "preserves an existing pull request canonical state during convergence" do
    issue = %SymphonyElixir.Tracker.Issue{
      id: "forgejo:issue:42",
      identifier: "Forgejo #42",
      title: "Issue 42",
      description: "",
      state: "Planned",
      kind: :issue,
      labels: ["sym:planned"]
    }

    existing =
      raw_pull(55, "head-55", [%{"id" => 3, "name" => "sym:review"}])
      |> put_in(["head", "ref"], "symphony/_42")

    converged =
      raw_pull(55, "head-55", [%{"id" => 3, "name" => "sym:review"}])
      |> put_in(["head", "ref"], "symphony/_42")

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues", response(200, [])},
      {:get, "/api/v1/repos/acme/widgets", response(200, %{"default_branch" => "main"})},
      {:get, "/api/v1/repos/acme/widgets/pulls", response(200, [existing])},
      {:get, "/api/v1/repos/acme/widgets/issues/55", response(200, existing)},
      {:get, "/api/v1/repos/acme/widgets/labels", response(200, [%{"id" => 3, "name" => "sym:review"}])},
      {:get, "/api/v1/repos/acme/widgets/pulls/55", response(200, converged)}
    ])

    assert {:ok, %{id: "forgejo:pr:55", state: "Review"}} =
             Client.create_pull_request_for_issue(issue)

    assert_requests_consumed()
  end

  test "uses configured human-intent labels when projecting Forgejo labels" do
    write_custom_human_intent_labels!()

    issue =
      raw_issue(56, [
        %{"id" => 1, "name" => "bug"},
        %{"id" => 2, "name" => "sym:planned"},
        %{"id" => 3, "name" => "symphony:operator-plan"}
      ])

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/56", response(200, issue)},
      {:get, "/api/v1/repos/acme/widgets/labels", response(200, [%{"id" => 7, "name" => "sym:review"}])},
      {:put, "/api/v1/repos/acme/widgets/issues/56/labels",
       fn opts ->
         assert Keyword.fetch!(opts, :json) == %{labels: [1, 7]}
         response(200, [])
       end},
      {:get, "/api/v1/repos/acme/widgets/issues/56/labels", response(200, [%{"id" => 1, "name" => "bug"}, %{"id" => 7, "name" => "sym:review"}])}
    ])

    assert {:applied, %{state: "Review", labels: ["bug", "sym:review"]}} =
             Client.apply_state_projection("forgejo:issue:56", "Planned", "Review")

    assert_requests_consumed()
  end

  test "uses one denominator for split children and their integration pull request" do
    issue = %SymphonyElixir.Tracker.Issue{title: "Split work"}
    sections = [%{number: 1, title: "API"}, %{number: 2, title: "UI"}]

    assert Client.pull_title_for_test(issue, %{number: 42, section: Enum.at(sections, 0), sections: sections}) ==
             "[1/3] Issue #42: API"

    assert Client.pull_title_for_test(issue, %{integration?: true, number: 42, sections: sections}) ==
             "[3/3] Issue #42: Split work integration"
  end

  test "paginates Forgejo issues with page and limit before combining pull requests" do
    first_page =
      Enum.map(1..50, fn number ->
        raw_issue(number, [%{"id" => 2, "name" => "sym:planned"}])
      end)

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues",
       fn opts ->
         assert Keyword.fetch!(opts, :params) == %{
                  state: "all",
                  type: "issues",
                  page: 1,
                  limit: 50
                }

         response(200, first_page)
       end},
      {:get, "/api/v1/repos/acme/widgets/issues",
       fn opts ->
         assert Keyword.fetch!(opts, :params) == %{
                  state: "all",
                  type: "issues",
                  page: 2,
                  limit: 50
                }

         response(200, [])
       end},
      {:get, "/api/v1/repos/acme/widgets/pulls",
       fn opts ->
         assert Keyword.fetch!(opts, :params) == %{state: "all", page: 1, limit: 50}
         response(200, [])
       end}
    ])

    assert {:ok, issues} = Client.fetch_issues_by_states(["Planned"])
    assert length(issues) == 50
    assert_requests_consumed()
  end

  test "creates a marked comment only once" do
    marker = "<!-- symphony:transition:abc -->"

    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/issues/8/comments", response(200, [%{"body" => "done\n#{marker}"}])}
    ])

    assert :already_applied = Client.create_comment_once("forgejo:issue:8", "done", marker)
    assert_requests_consumed()
  end

  test "squash merge pins the head commit and verifies the merged pull" do
    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "head-12", []))},
      {:post, "/api/v1/repos/acme/widgets/pulls/12/merge",
       fn opts ->
         assert Keyword.fetch!(opts, :json) == %{Do: "squash", head_commit_id: "head-12"}
         response(200, %{})
       end},
      {:get, "/api/v1/repos/acme/widgets/pulls/12",
       response(
         200,
         raw_pull(12, "head-12", [], %{"merged" => true, "merge_commit_sha" => "merge-12"})
       )}
    ])

    assert {:applied,
            %{
              issue_id: "forgejo:pr:12",
              merged: true,
              already_applied: false,
              head_oid: "head-12",
              merge_commit_sha: "merge-12"
            }} = Client.merge_pull_request("forgejo:pr:12", "head-12")

    assert_requests_consumed()
  end

  test "squash merge rejects a stale expected head before writing" do
    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "new-head", []))}
    ])

    assert {:conflict,
            %{
              issue_id: "forgejo:pr:12",
              expected_head_oid: "old-head",
              current_head_oid: "new-head"
            }} = Client.merge_pull_request("forgejo:pr:12", "old-head")

    assert_requests_consumed()
  end

  test "squash merge retries a pending mergeability response only after rechecking the head" do
    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "head-12", []))},
      {:post, "/api/v1/repos/acme/widgets/pulls/12/merge", response(405, %{"message" => "Please try again later"})},
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "head-12", []))},
      {:post, "/api/v1/repos/acme/widgets/pulls/12/merge", response(200, %{})},
      {:get, "/api/v1/repos/acme/widgets/pulls/12",
       response(
         200,
         raw_pull(12, "head-12", [], %{"merged" => true, "merge_commit_sha" => "merge-12"})
       )}
    ])

    assert {:applied, %{merged: true, head_oid: "head-12"}} =
             Client.merge_pull_request("forgejo:pr:12", "head-12")

    assert_requests_consumed()
  end

  test "squash merge does not retry a permanent 405 response" do
    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "head-12", []))},
      {:post, "/api/v1/repos/acme/widgets/pulls/12/merge", response(405, %{"message" => "Squash merges are disabled"})}
    ])

    assert {:error,
            %{
              stage: :merge,
              reason: {:forgejo_api_status, 405, %{"message" => "Squash merges are disabled"}}
            }} =
             Client.merge_pull_request("forgejo:pr:12", "head-12")

    assert_requests_consumed()
  end

  test "squash merge rejects a different head merged while waiting for mergeability" do
    stub_requests([
      {:get, "/api/v1/repos/acme/widgets/pulls/12", response(200, raw_pull(12, "head-12", []))},
      {:post, "/api/v1/repos/acme/widgets/pulls/12/merge", response(405, %{"message" => "Please try again later"})},
      {:get, "/api/v1/repos/acme/widgets/pulls/12",
       response(
         200,
         raw_pull(12, "drifted-head", [], %{"merged" => true, "merge_commit_sha" => "other-merge"})
       )}
    ])

    assert {:conflict,
            %{
              issue_id: "forgejo:pr:12",
              expected_head_oid: "head-12",
              current_head_oid: "drifted-head"
            }} = Client.merge_pull_request("forgejo:pr:12", "head-12")

    assert_requests_consumed()
  end

  defp forgejo_config do
    [
      tracker_kind: "forgejo",
      tracker_endpoint: "https://forgejo.example/api/v1",
      tracker_api_token: "secret",
      tracker_owner: "acme",
      tracker_repo: "widgets",
      tracker_project_slug: nil,
      tracker_bot_login: "symphony"
    ]
  end

  defp write_custom_human_intent_labels! do
    workflow_path = Workflow.workflow_file_path()

    workflow_path
    |> File.read!()
    |> String.replace(
      "polling:",
      "state_manager:\n  human_intent_labels: {\"Planned\": \"symphony:operator-plan\"}\npolling:",
      global: false
    )
    |> then(&File.write!(workflow_path, &1))

    SymphonyElixir.WorkflowStore.force_reload()
  end

  defp stub_requests(expectations) do
    test_pid = self()
    Agent.start_link(fn -> expectations end, name: request_agent_name())

    Application.put_env(:symphony_elixir, :forgejo_request_fun, fn opts ->
      method = Keyword.fetch!(opts, :method)
      path = opts |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:path)
      send(test_pid, {:forgejo_request, method, path})

      Agent.get_and_update(request_agent_name(), &respond_to_stub(&1, method, path, opts))
    end)
  end

  defp respond_to_stub([{method, path, responder} | rest], method, path, opts) do
    result = if is_function(responder, 1), do: responder.(opts), else: responder
    {result, rest}
  end

  defp respond_to_stub([next | _] = pending, method, path, _opts),
    do: {{:error, {:unexpected_request, method, path, next}}, pending}

  defp respond_to_stub([], method, path, _opts),
    do: {{:error, {:unexpected_request, method, path, :empty}}, []}

  defp assert_requests_consumed do
    assert Agent.get(request_agent_name(), & &1) == []
    Agent.stop(request_agent_name())
  end

  defp request_agent_name, do: Module.concat(__MODULE__, RequestAgent)
  defp response(status, body), do: {:ok, %{status: status, body: body}}

  defp raw_issue(number, labels) do
    %{
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Body",
      "state" => "open",
      "labels" => labels,
      "html_url" => "https://forgejo.example/acme/widgets/issues/#{number}",
      "created_at" => "2026-07-20T00:00:00Z",
      "updated_at" => "2026-07-20T00:00:00Z"
    }
  end

  defp raw_pull(number, sha, labels, overrides \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "Pull #{number}",
        "body" => "Body",
        "state" => "open",
        "merged" => false,
        "labels" => labels,
        "html_url" => "https://forgejo.example/acme/widgets/pulls/#{number}",
        "head" => %{
          "ref" => "symphony/_7",
          "sha" => sha,
          "repo" => %{"id" => 1, "full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}
        },
        "base" => %{"ref" => "main", "repo" => %{"id" => 1, "full_name" => "acme/widgets", "html_url" => "https://forgejo.example/acme/widgets"}}
      },
      overrides
    )
  end
end
