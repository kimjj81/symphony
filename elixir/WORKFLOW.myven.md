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
  after_sync_local_files: |
    pnpm run worktree:copy-env
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
  before_remove: |
    workspace_root="$(pwd)"
    workspace_physical_root="$(pwd -P 2>/dev/null || pwd)"
    workspace_hook_root="${SYMPHONY_WORKSPACE:-}"
    compose_file="${workspace_root}/infra/local/docker-compose.yml"
    env_file="${workspace_root}/.env.local"

    if [ ! -f "$compose_file" ]; then
      printf "WARN: skipped Myven compose cleanup; missing %s\n" "$compose_file" >&2
      exit 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
      printf "WARN: skipped Myven compose cleanup; docker command not found\n" >&2
      exit 0
    fi

    export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/myven-docker-config}"
    mkdir -p "$DOCKER_CONFIG" 2>/dev/null || true

    projects_file="${TMPDIR:-/tmp}/myven-compose-cleanup-projects-$$"
    : > "$projects_file"
    trap 'rm -f "$projects_file"' EXIT

    add_compose_project() {
      project="$1"
      case "$project" in
        myven_*)
          if ! grep -qxF "$project" "$projects_file" 2>/dev/null; then
            printf "%s\n" "$project" >> "$projects_file"
          fi
          ;;
      esac
    }

    working_dir_belongs_to_workspace() {
      working_dir="$1"

      case "$working_dir" in
        "$workspace_root"|"$workspace_root"/*)
          return 0
          ;;
      esac

      if [ "$workspace_physical_root" != "$workspace_root" ]; then
        case "$working_dir" in
          "$workspace_physical_root"|"$workspace_physical_root"/*)
            return 0
            ;;
        esac
      fi

      if [ -n "$workspace_hook_root" ]; then
        case "$working_dir" in
          "$workspace_hook_root"|"$workspace_hook_root"/*)
            return 0
            ;;
        esac
      fi

      return 1
    }

    if [ -f "$env_file" ]; then
      env_project="$(
        awk -F= '
          $1 == "COMPOSE_PROJECT_NAME" {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^["'"'"']|["'"'"']$/, "", value)
            print value
          }
        ' "$env_file" | tail -n 1
      )"
      [ -n "$env_project" ] && add_compose_project "$env_project"
    fi

    docker ps -a \
      --filter label=com.docker.compose.project \
      --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' \
      2>/dev/null |
      while IFS='|' read -r project working_dir; do
        if working_dir_belongs_to_workspace "$working_dir"; then
          add_compose_project "$project"
        fi
      done

    if [ ! -s "$projects_file" ]; then
      printf "INFO: no Myven compose projects found for %s\n" "$workspace_root"
      exit 0
    fi

    cleanup_failed=0
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      printf "INFO: removing Myven compose project %s\n" "$project"

      if [ -f "$env_file" ]; then
        docker compose --profile tools --env-file "$env_file" -p "$project" -f "$compose_file" down -v --remove-orphans ||
          cleanup_failed=1
      else
        docker compose --profile tools -p "$project" -f "$compose_file" down -v --remove-orphans ||
          cleanup_failed=1
      fi
    done < "$projects_file"

    exit "$cleanup_failed"
agent:
  max_concurrent_agents: 3
  max_turns: 3
  dispatch_kinds:
    - issue
    - pull_request
  source_checkout_states:
    - Todo
codex:
  command: codex app-server
  task_profiles:
    single_file_edit:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=low app-server
      model: gpt-5.5
      effort: low
    bug_with_test_log:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=medium app-server
      model: gpt-5.5
      effort: medium
    unknown_bug:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
      model: gpt-5.5
      effort: high
    multi_file_refactor:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
      model: gpt-5.5
      effort: high
    feature_without_tests:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
      model: gpt-5.5
      effort: xhigh
    default:
      command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=medium app-server
      model: gpt-5.5
      effort: medium
  approval_policy: on-request
  auto_approve_command_patterns:
    - pnpm e2e
    - pnpm exec playwright
    - bash ./scripts/playwright-local.sh
    - ./scripts/playwright-local.sh
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

Reasoning profile policy:
| 작업 유형 | 기본 정책 |
| --- | --- |
| 명확한 단일 파일 수정 | 짧은 reasoning: `gpt-5.5` + `low` effort |
| 테스트 실패 로그가 있는 버그 | 중간 reasoning: `gpt-5.5` + `medium` effort, 테스트 로그 포함 |
| 원인 불명 버그 | 긴 reasoning: `gpt-5.5` + `high` effort, 먼저 진단 계획 |
| 다중 파일 리팩터 | 긴 reasoning: `gpt-5.5` + `high` effort, plan 먼저 + patch 나중 |
| 테스트가 없는 기능 추가 | 강한 reasoning: `gpt-5.5` + `xhigh` effort, 테스트 설계 먼저 |

Instructions:
1. GitHub Todo issues are planning-only Codex runs. Implementation work belongs to pull request lanes; when a GitHub issue enters Planned, Symphony's control path may create or reuse a PR for that issue without implementing in the source issue lane.
2. Keep changes scoped and minimal.
3. Prefer safe, deterministic changes and record blockers in the workpad.
4. Use the GitHub labels as the state machine: sym:todo, sym:planned, sym:in-progress, sym:review, sym:reviewing, sym:human-review, sym:rework, sym:merging, sym:done, sym:canceled, sym:duplicate.
5. If Codex goal support is available, create exactly one active goal for the current tracker-state objective and keep it aligned with the label state machine. The goal is a scope guard, not permission to expand work.
   - Todo issue goal: planning-only handoff, no repository edits, then Human Review.
   - Planned issue goal: create or reuse the implementation PR, then return the source issue to Human Review.
   - Planned or Rework PR goal: implement only the approved or requested change, validate, self-review, then move the PR to Review.
   - Review or Reviewing PR goal: review only; move the PR to Rework on findings or Human Review when clean.
   - Merging goal: verify merge readiness, follow repository merge policy, merge, then move the item to Done.
   - Mark the goal complete only after the matching state transition and required GitHub/workpad synchronization are done.
6. Do not spawn supervisor agents in this unattended Symphony run. For implementation runs, do not spawn reviewer or specialist agents; perform the required self-review instead.
7. For Review or Reviewing pull request runs, use code-review and security-review agents or equivalent reviewer roles when available. If repository instructions otherwise require supervisor agents, treat Symphony as the supervisor.
8. Do not call tools that require interactive MCP elicitation or human input; record the blocker and stop if no non-interactive path exists.
   - Non-interactive headless Playwright MCP is allowed for local UI verification, console inspection, screenshots, and deterministic browser checks.
   - Do not use headed browsers, browser extensions, login prompts, captchas, or any MCP flow that requires human input in unattended Symphony runs.
   - If headless browser automation is unavailable, record the blocker and continue with the narrowest non-browser validation.
   - Repo-local Playwright/E2E commands may need to run outside the Codex sandbox on macOS. For `pnpm e2e*`, `pnpm exec playwright`, or `bash ./scripts/playwright-local.sh ...`, use `sandbox_permissions=require_escalated` with a concise justification from the start. Symphony is configured to auto-approve only these command patterns.
   - If Chromium fails with `MachPortRendezvousServer`, `bootstrap_check_in`, Crashpad, or `Permission denied (1100)`, retry the same Playwright/E2E command once with `sandbox_permissions=require_escalated` before treating it as an application failure.
9. For local URLs and browser/smoke verification, read the current worktree's `.env.local` and use its `MYVEN_*_PORT` values. Do not assume the default ports such as 4999, 8080, 8000, 8100, 5433, or 4566 are free in a Symphony worktree.
10. Write GitHub issue comments, issue bodies, pull request titles, pull request descriptions, and pull request comments in Korean unless quoting source text or preserving an existing external title.
   - When creating a stacked child pull request whose base branch belongs to another open pull request, prefix the child PR title with the parent PR number in the format `PR #<parent>: <child PR title>`, and mention the parent PR in the PR body.
11. If this item is a GitHub issue in Todo, do not implement code and do not create, modify, commit, or push repository files, including `docs/draft/*`. Analyze the issue, record the plan only in the issue body or a GitHub comment, propose PR-sized work items in a GitHub comment, then move the item to Human Review.
12. If this item is a GitHub issue in Planned, do not implement in the issue lane. Create or reuse PR-sized implementation pull request(s) without creating a source-issue worktree, label each PR Planned for implementation, then move the source issue to Human Review.
   - If the issue body has explicit `### PR1`, `### PR2`, or later PR-sized sections, do not create a single catch-all implementation PR.
   - By default, treat split PR sections as sequential: create or reuse only the first PR section branch, for example `symphony/_84-pr1`, and leave later sections listed as follow-up PRs.
   - If the issue explicitly says `PR 진행 방식: 병렬` or `execution mode: parallel`, create or reuse one PR per section, for example `symphony/_84-pr1` and `symphony/_84-pr2`.
   - Split PR bodies should use `Refs #<issue>` while follow-up PR sections remain, not `Closes #<issue>`.
   - If the issue has native GitHub sub-issues, treat the parent as a coordination issue and create/reuse the implementation PR for the first open `sym:planned` sub-issue instead. The child PR must close only the child issue and reference the parent with `Refs #<parent>`.
   - A native GitHub parent issue may be marked Done/closed only after every sub-issue is terminal (`Done`, `Canceled`, or `Duplicate`). If any sub-issue remains non-terminal, keep or reopen the parent in Human Review.
13. Symphony must not move a GitHub issue from Todo or Human Review to Planned by itself. Only a human-applied sym:planned label is an approval gate.
14. If a Planned issue is explicitly a planning/splitting issue, create the requested PR-sized follow-up issues instead of changing product code. Label follow-up implementation issues sym:planned only when the parent issue explicitly asks for immediate execution; otherwise label them sym:todo for human review. If a direct implementation PR is needed, create the PR and let the PR lane do the work.
15. If this item is a GitHub issue with an open linked pull request, keep or move the source issue to Human Review, update only the issue summary/comment and the linked PR body/comment with current PR status, then stop; PR execution belongs to the linked pull request.
16. If this item is a GitHub issue in In Progress and it does not have an open linked pull request, create or update a PR-sized implementation PR and keep the issue comment trail current. After opening or updating the implementation PR, move only the PR to Review and keep the source issue in Human Review while updating the source issue summary/comment with the PR status.
17. If implementation becomes too large, stop before committing and comment: "이 PR은 너무 커졌으므로 여기까지 commit하지 않고 분할 제안". Move the item to Human Review with the split proposal.
18. If this item is a pull request in Todo, improve the PR description, implementation plan, and validation plan, then move it to Human Review.
19. If this item is a pull request in Planned, move it to In Progress, implement the approved change, run the narrowest useful validation, complete the self-review checklist, comment with results, move only the PR to Review, and keep the source issue in Human Review while updating the PR body/comment and source issue summary/comment with the PR status.
20. If this item is a pull request in Review or Reviewing, perform automated code review and security review. If there are no required improvements, synchronize the PR body/comment and relevant docs/workpad, move only the PR to Human Review, and keep the source issue in Human Review. If improvements are required, leave a PR comment with findings, move only the PR to Rework, and keep the source issue in Human Review while updating the source issue summary/comment with the blocker summary.
21. If this item is a pull request in Rework, read the latest GitHub review comments and PR comments first, address only the requested follow-up changes, comment with results, move only the PR to Review, and keep the source issue in Human Review while updating only the PR body/comment and source issue summary/comment. Do not move the source issue to Review, Reviewing, Rework, or In Progress while the PR remains open. Split new features or large design changes into a new issue instead of expanding PR Rework.
22. If this item is a GitHub issue in Rework and it has an open linked pull request, do not implement or review in the issue lane. Keep or move the issue to Human Review, add a Korean comment pointing to the linked PR and its current rework status, then stop. If there is no open linked pull request, treat it as issue-only Rework: read the latest issue comments first, clarify the requested issue-level follow-up in a Korean issue comment, and move the issue to Human Review unless a human explicitly applies Planned.
23. Human Review is a review-retention state, not a cleanup state. Do not delete or recreate the generated PR workspace while a PR is in Human Review; the same directory must remain available for manual re-review and later Rework.
24. If this item is in Merging, treat it as approved merge work. Use the existing generated workspace and current PR branch, verify the PR is mergeable, follow repository merge instructions, and move the item to Done only after the merge succeeds.
   - Before merging, inspect the code changed by this PR for user-facing text that bypasses the repository's i18n/localization path. If untranslated literals or missing locale entries are found, add the required translations and focused i18n verification in the PR branch before merging.
25. Cleanup is allowed only after a true final state: Done, Canceled, or Duplicate.
26. For GitHub issues, terminal state labels must match the GitHub open/closed state: `sym:done` closes as completed, and `sym:canceled` or `sym:duplicate` close as not planned. Moving an issue back to a non-terminal Symphony label should reopen it.
27. Do not continue working after moving the item to Human Review.
28. If durable documentation is needed for a Todo issue, defer it to an approved Planned PR-sized work item and commit it on that PR branch. Do not reference local-only scratch file paths in issue comments.
29. Before moving a Todo GitHub issue to Human Review, run `git status --short --untracked-files=all` and confirm there are no task-authored repository changes.
30. Before moving an implementation PR to Review, record this self-review checklist in the PR body or comment: tenant/RLS, migration/backfill, idempotency/retry/replay, local/prod URL, secret/token exposure, browser-visible terminology, and fixture/local smoke preservation.
31. Preserve `docs/draft` workpads through Human Review. Before Merging, either move durable content into `docs/architecture`, `docs/design-system`, or `docs/adr`, or remove the draft-only workpad.
