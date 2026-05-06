---
tracker:
  kind: github
  owner: studiojin-dev
  repo: myven
  api_key: $GITHUB_TOKEN
  active_states:
    - Todo
    - Planned
    - In Progress
    - Review
    - Reviewing
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
    - Duplicate
  state_labels:
    Todo: sym:todo
    Planned: sym:planned
    In Progress: sym:in-progress
    Review: sym:review
    Reviewing: sym:reviewing
    Human Review: sym:human-review
    Rework: sym:rework
    Merging: sym:merging
    Done: sym:done
    Canceled: sym:canceled
    Duplicate: sym:duplicate
polling:
  interval_ms: 30000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
  strategy: git_worktree
  source: $MYVEN_REPO_ROOT 
  base_ref: origin/main
  local_files:
    - path: .env.local
      mode: copy
      required: false
    - path: .env
      mode: copy
      required: false
    - path: .pnpm-store
      mode: symlink
      required: false
hooks:
  after_create: |
    : "${CODEX_WS_HOST:=127.0.0.1}"
    : "${CODEX_WS_PORT:=4500}"
    : "${CODEX_WS_URL:=ws://${CODEX_WS_HOST}:${CODEX_WS_PORT}}"
    : "${CODEX_APPSERVER_DAEMON:="$HOME/.cache/codex/codex-appserver-daemon.sh"}"
    if [ -x "$CODEX_APPSERVER_DAEMON" ]; then
      CODEX_WS_HOST="$CODEX_WS_HOST" CODEX_WS_PORT="$CODEX_WS_PORT" CODEX_WS_URL="$CODEX_WS_URL" \
      "$CODEX_APPSERVER_DAEMON" || true
    else
      printf "WARN: codex app-server daemon not found: %s\n" "$CODEX_APPSERVER_DAEMON" >&2
    fi

    [ -f .env.local ] || : > .env.local

    upsert_env_var() {
      name="$1"
      value="$2"
      awk -v name="$name" -v value="$value" '
        BEGIN { prefix = name "="; found = 0 }
        index($0, prefix) == 1 {
          if (!found) print prefix value
          found = 1
          next
        }
        { print }
        END { if (!found) print prefix value }
      ' .env.local > .env.local.tmp && mv .env.local.tmp .env.local
    }

    compose_project_suffix="$(printf '%s' "$SYMPHONY_ISSUE_IDENTIFIER" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')"
    compose_project_name="myven_${compose_project_suffix}"
    upsert_env_var COMPOSE_PROJECT_NAME "$compose_project_name"

    random_port_base="$(awk -v seed="$(date +%s)$$" 'BEGIN { srand(seed); print int(50000 + rand() * 9000) }')"
    upsert_port_var() {
      name="$1"
      offset="$2"
      upsert_env_var "$name" "$((random_port_base + offset))"
    }

    myven_web_port="$((random_port_base + 1))"
    upsert_port_var MYVEN_GATEWAY_PORT 0
    upsert_port_var MYVEN_WEB_PORT 1
    upsert_port_var MYVEN_API_PORT 2
    upsert_port_var MYVEN_WEBHOOKS_PORT 3
    upsert_port_var MYVEN_POSTGRES_PORT 4
    upsert_port_var MYVEN_LOCALSTACK_PORT 5
    upsert_port_var MYVEN_MAILPIT_SMTP_PORT 6
    upsert_port_var MYVEN_MAILPIT_UI_PORT 7
    upsert_port_var MYVEN_OTEL_GRPC_PORT 8
    upsert_port_var MYVEN_OTEL_HTTP_PORT 9
    upsert_port_var MYVEN_OTEL_HEALTH_PORT 10
    upsert_port_var MYVEN_OTEL_METRICS_PORT 11
    upsert_env_var MYVEN_LOCAL_BASE_URL "http://127.0.0.1:${myven_web_port}"

    if [ -f package.json ] && command -v pnpm >/dev/null 2>&1; then
      pnpm run worktree:bootstrap
    else
      printf "WARN: skipped worktree bootstrap; package.json or pnpm not found\n" >&2
    fi
  before_remove: |
    :
agent:
  max_concurrent_agents: 2
  max_turns: 3
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  read_timeout_ms: 10000

  # To keep a shared WS daemon, run Codex through codex-ws.sh.
  # The wrapper reads ~/.config/codex/appserver.env, ~/.codex/appserver.env, and .env.
  # It starts app-server once, then connects the CLI with --remote ws://127.0.0.1:4500.
  #   alias codex-ws="/path/to/codex-ws.sh"
  #   codex-ws
  #   codex-ws app
  # Symphony's codex.command path still uses stdio unless the runner is changed.
notifications:
  discord:
    enabled: true
    webhook_url: $DISCORD_WEBHOOK_URL
    notify_states:
      - Human Review
      - Done
      - Canceled
      - Cancelled
      - Closed
      - Duplicate
  cmux:
    enabled: true
    command: cmux
    notify_states:
      - Human Review
      - Done
      - Canceled
      - Cancelled
      - Closed
      - Duplicate
---

You are working on a GitHub tracker item `{{ issue.identifier }}`.

Tracker context:
- Identifier: {{ issue.identifier }}
- Kind: {{ issue.kind }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}{{ issue.description }}{% else %}No description provided.{% endif %}

Instructions:
1. Work only in the workspace generated for this ticket.
2. Keep changes scoped and minimal.
3. Prefer safe, deterministic changes and record blockers in the workpad.
4. Use the GitHub labels as the state machine: sym:todo, sym:planned, sym:in-progress, sym:review, sym:reviewing, sym:human-review, sym:rework, sym:merging, sym:done, sym:canceled, sym:duplicate.
5. Do not spawn supervisor agents in this unattended Symphony run. For implementation runs, do not spawn reviewer or specialist agents; perform the required self-review instead.
6. For Review or Reviewing pull request runs, use code-review and security-review agents or equivalent reviewer roles when available. If repository instructions otherwise require supervisor agents, treat Symphony as the supervisor.
7. Do not call tools that require interactive MCP elicitation or human input; record the blocker and stop if no non-interactive path exists.
   - Non-interactive headless Playwright MCP is allowed for local UI verification, console inspection, screenshots, and deterministic browser checks.
   - Do not use headed browsers, browser extensions, login prompts, captchas, or any MCP flow that requires human input in unattended Symphony runs.
   - If headless browser automation is unavailable, record the blocker and continue with the narrowest non-browser validation.
8. For local URLs and browser/smoke verification, read the current worktree's `.env.local` and use its `MYVEN_*_PORT` values. Do not assume the default ports such as 4999, 8080, 8000, 8100, 5433, or 4566 are free in a Symphony worktree.
9. Write GitHub issue comments, issue bodies, pull request titles, pull request descriptions, and pull request comments in Korean unless quoting source text or preserving an existing external title.
10. If this item is a GitHub issue in Todo, do not implement code and do not create, modify, commit, or push repository files, including `docs/draft/*`. Analyze the issue, record the plan only in the issue body or a GitHub comment, propose PR-sized work items in a GitHub comment, then move the item to Human Review.
11. If this item is a GitHub issue in Planned, treat Planned as explicit human approval to execute only when the issue has `## 결정 사항` and `## 완료 기준` sections, required ADR coverage for schema/auth/secret/RLS/deploy changes, and 12 or fewer expected files. If any gate fails, do not implement; comment with the blocker and move it to Human Review.
12. Symphony must not move a GitHub issue from Todo or Human Review to Planned by itself. Only a human-applied sym:planned label is an approval gate.
13. If a Planned issue is explicitly a planning/splitting issue, create the requested PR-sized follow-up issues instead of changing product code. Label follow-up implementation issues sym:planned only when the parent issue explicitly asks for immediate execution; otherwise label them sym:todo for human review.
14. If this item is a GitHub issue with an open linked pull request, exclude the source issue from active dispatch work even when it has an active label such as Review, Reviewing, Rework, or In Progress. Keep or move the source issue to Human Review, update only the issue summary/comment and the linked PR body/comment with current PR status, then stop; PR execution belongs to the linked pull request.
15. If this item is a GitHub issue in In Progress and it does not have an open linked pull request, create or update PR-sized implementation work and keep the issue comment trail current. After implementation, open or update the implementation PR, complete the self-review checklist, move only the PR to Review, and keep the source issue in Human Review while updating the source issue summary/comment with the PR status.
16. If implementation becomes too large, stop before committing and comment: "이 PR은 너무 커졌으므로 여기까지 commit하지 않고 분할 제안". Move the item to Human Review with the split proposal.
17. If this item is a pull request in Todo, improve the PR description, implementation plan, and validation plan, then move it to Human Review.
18. If this item is a pull request in Planned, move it to In Progress, implement the approved change, run the narrowest useful validation, complete the self-review checklist, comment with results, move only the PR to Review, and keep the source issue in Human Review while updating the PR body/comment and source issue summary/comment with the PR status.
19. If this item is a pull request in Review or Reviewing, perform automated code review and security review. If there are no required improvements, synchronize the PR body/comment and relevant docs/workpad, move only the PR to Human Review, and keep the source issue in Human Review. If improvements are required, leave a PR comment with findings, move only the PR to Rework, and keep the source issue in Human Review while updating the source issue summary/comment with the blocker summary.
20. If this item is a pull request in Rework, read the latest GitHub review comments and PR comments first, address only the requested follow-up changes, comment with results, move only the PR to Review, and keep the source issue in Human Review while updating only the PR body/comment and source issue summary/comment. Do not move the source issue to Review, Reviewing, Rework, or In Progress while the PR remains open. Split new features or large design changes into a new issue instead of expanding PR Rework.
21. If this item is a GitHub issue in Rework and it has an open linked pull request, do not implement or review in the issue workspace. Keep or move the issue to Human Review, add a Korean comment pointing to the linked PR and its current rework status, then stop. If there is no open linked pull request, treat it as issue-only Rework: read the latest issue comments first, clarify the requested issue-level follow-up in a Korean issue comment, and move the issue to Human Review unless a human explicitly applies Planned or In Progress.
22. Human Review is a review-retention state, not a cleanup state. Do not delete or recreate the generated workspace while an issue or PR is in Human Review; the same directory must remain available for manual re-review and later Rework.
23. If this item is in Merging, treat it as approved merge work. Use the existing generated workspace and current PR branch, verify the PR is mergeable, follow repository merge instructions, and move the item to Done only after the merge succeeds.
24. Cleanup is allowed only after a true final state: Done, Canceled, or Duplicate.
25. For GitHub issues, terminal state labels must match the GitHub open/closed state: `sym:done` closes as completed, and `sym:canceled` or `sym:duplicate` close as not planned. Moving an issue back to a non-terminal Symphony label should reopen it.
26. Do not continue working after moving the item to Human Review.
27. If durable documentation is needed for a Todo issue, defer it to an approved Planned PR-sized work item and commit it on that PR branch. Do not reference local-only scratch file paths in issue comments.
28. Before moving a Todo GitHub issue to Human Review, run `git status --short --untracked-files=all` and confirm there are no task-authored repository changes.
29. Before moving an implementation PR to Review, record this self-review checklist in the PR body or comment: tenant/RLS, migration/backfill, idempotency/retry/replay, local/prod URL, secret/token exposure, browser-visible terminology, and fixture/local smoke preservation.
30. Preserve `docs/draft` workpads through Human Review. Before Merging, either move durable content into `docs/architecture`, `docs/design-system`, or `docs/adr`, or remove the draft-only workpad.
