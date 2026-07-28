defmodule SymphonyElixir.HostedGitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.HostedGit

  test "shares label policy across hosted-git providers" do
    assert HostedGit.state_labels(nil) == HostedGit.default_state_labels()
    assert HostedGit.classify_managed_label(nil, nil) == :unmanaged
    assert HostedGit.label_for_state("review", nil) == "sym:review"
    assert HostedGit.state_for_label("SYM:REVIEW", nil) == "Review"
  end

  test "classifies configured human-intent request labels" do
    custom_labels = %{"Planned" => "symphony:operator-plan"}

    assert HostedGit.classify_managed_label("SYMPHONY:OPERATOR-PLAN", nil, custom_labels) ==
             {:request, "Planned"}
  end

  test "recognizes only configured Codex review-bot comments" do
    assert HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => %{"login" => "CHATGPT-CODEX-CONNECTOR"}}
           })

    refute HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => %{"login" => "maintainer"}}
           })
  end

  test "normalizes configured Codex review-bot logins" do
    previous = System.get_env("SYMPHONY_CODEX_REVIEW_BOT_LOGINS")
    System.put_env("SYMPHONY_CODEX_REVIEW_BOT_LOGINS", "  CUSTOM-CODEX, secondary-bot  ")

    on_exit(fn ->
      if previous, do: System.put_env("SYMPHONY_CODEX_REVIEW_BOT_LOGINS", previous), else: System.delete_env("SYMPHONY_CODEX_REVIEW_BOT_LOGINS")
    end)

    assert HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => %{"login" => "custom-codex"}}
           })
  end

  test "handles malformed review-comment authors without raising" do
    assert HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => nil},
             "sender" => %{"login" => "chatgpt-codex-connector"}
           })

    assert HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => "unexpected"},
             "sender" => %{"login" => "chatgpt-codex-connector"}
           })

    refute HostedGit.codex_review_comment?(%{
             "comment" => %{"user" => %{"login" => "maintainer"}},
             "sender" => %{"login" => "chatgpt-codex-connector"}
           })

    for user <- [nil, "unexpected", %{}, %{"login" => nil}, %{"login" => "  "}] do
      refute HostedGit.codex_review_comment?(%{"comment" => %{"user" => user}, "sender" => nil})
    end

    refute HostedGit.codex_review_comment?(%{"comment" => "unexpected"})
  end

  test "encodes provider-qualified IDs and decodes compatibility display IDs" do
    assert HostedGit.encode_id("forgejo", :issue, 12) == "forgejo:issue:12"
    assert HostedGit.encode_id("forgejo", :pull_request, 13) == "forgejo:pr:13"
    assert HostedGit.decode_id("forgejo", "#12") == {:ok, 12, :issue}
    assert HostedGit.decode_id("forgejo", "PR #13") == {:ok, 13, :pull_request}
    assert HostedGit.decode_id("forgejo", "14") == {:ok, 14, nil}
    assert HostedGit.decode_id("forgejo", "invalid") == :error
  end

  test "parses split pull-request plans and their execution mode" do
    description = """
    실행 방식: 병렬

    ### PR1: API
    Implement the API.

    ### PR2: UI
    Implement the UI.
    """

    assert [
             %{number: 1, title: "API", body: "Implement the API."},
             %{number: 2, title: "UI", body: "Implement the UI."}
           ] = HostedGit.pull_request_sections(description)

    assert HostedGit.parallel_pull_request_plan?(description)
    refute HostedGit.parallel_pull_request_plan?("### PR1: sequential")
  end

  test "rejects split pull-request plans with gaps, duplicates, or non-one-based numbering" do
    assert :ok =
             HostedGit.validate_pull_request_sections([
               %{number: 1, title: "API"},
               %{number: 2, title: "UI"}
             ])

    assert {:error, {:invalid_pull_request_section_sequence, [1, 3]}} =
             HostedGit.validate_pull_request_sections([
               %{number: 1, title: "API"},
               %{number: 3, title: "UI"}
             ])
  end
end
