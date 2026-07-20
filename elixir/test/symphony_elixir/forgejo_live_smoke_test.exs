defmodule SymphonyElixir.ForgejoLiveSmokeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Forgejo.Client

  @moduletag :forgejo_live
  if System.get_env("SYMPHONY_RUN_FORGEJO_SMOKE") != "1" do
    @moduletag skip: "set SYMPHONY_RUN_FORGEJO_SMOKE=1 through make forgejo-smoke"
  end

  setup do
    api_url = System.fetch_env!("SYMPHONY_FORGEJO_SMOKE_API_URL")
    token = System.fetch_env!("SYMPHONY_FORGEJO_SMOKE_TOKEN")
    owner = System.fetch_env!("SYMPHONY_FORGEJO_SMOKE_OWNER")
    repo = System.fetch_env!("SYMPHONY_FORGEJO_SMOKE_REPO")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "forgejo",
      tracker_endpoint: api_url,
      tracker_api_token: token,
      tracker_project_slug: nil,
      tracker_owner: owner,
      tracker_repo: repo,
      tracker_bot_login: "symphony",
      tracker_active_states: ["Planned", "In Progress"],
      workspace_base_ref: "origin/main"
    )

    {:ok, api_url: api_url, token: token, owner: owner, repo: repo}
  end

  test "polls, projects, comments, creates a pull request, and performs a head-pinned squash merge", context do
    assert :ok = Client.preflight()

    planned_label = create_label(context, "sym:planned")

    issue =
      api!(context, :post, "/issues", %{
        title: "Forgejo smoke issue",
        body: "Exercise the Symphony Forgejo lifecycle.",
        labels: [planned_label["id"]]
      })

    issue_id = "forgejo:issue:#{issue["number"]}"
    assert {:ok, [normalized]} = Client.fetch_issues_by_states(["Planned"])
    assert normalized.id == issue_id

    assert {:applied, _metadata} = Client.apply_state_projection(issue_id, "Planned", "In Progress")
    assert {:applied, _metadata} = Client.apply_state_projection(issue_id, "In Progress", "Planned")
    assert :applied = Client.create_comment_once(issue_id, "Forgejo smoke comment", "forgejo-smoke-marker")
    assert :already_applied = Client.create_comment_once(issue_id, "Forgejo smoke comment", "forgejo-smoke-marker")

    assert {:ok, pull_request} = Client.create_pull_request_for_issue(normalized)
    assert pull_request.id =~ "forgejo:pr:"
    assert is_binary(pull_request.metadata.head_oid)

    _file =
      api!(context, :post, "/contents/forgejo-smoke.txt", %{
        branch: pull_request.branch_name,
        content: Base.encode64("forgejo smoke\n"),
        message: "test: seed Forgejo smoke pull request"
      })

    original_head_oid = pull_request.metadata.head_oid

    assert {:ok, [updated_pull_request]} = Client.fetch_issue_states_by_ids([pull_request.id])
    assert updated_pull_request.metadata.head_oid != original_head_oid

    assert {:conflict, %{expected_head_oid: ^original_head_oid, current_head_oid: current_head_oid}} =
             Client.merge_pull_request(pull_request.id, original_head_oid)

    assert current_head_oid == updated_pull_request.metadata.head_oid

    assert {:applied, merge} =
             Client.merge_pull_request(updated_pull_request.id, updated_pull_request.metadata.head_oid)

    assert merge.merged == true
  end

  defp create_label(context, name) do
    api!(context, :post, "/labels", %{name: name, color: "bfd4ff", description: "Forgejo smoke label"})
  end

  defp api!(context, method, path, body) do
    url = "#{context.api_url}/repos/#{context.owner}/#{context.repo}#{path}"

    case Req.request(method: method, url: url, headers: headers(context.token), json: body) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> response
      other -> flunk("Forgejo smoke API failed: #{inspect(other)}")
    end
  end

  defp headers(token) do
    [
      {"accept", "application/json"},
      {"authorization", "token #{token}"}
    ]
  end
end
