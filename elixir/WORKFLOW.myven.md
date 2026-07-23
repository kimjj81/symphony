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
    - Reworking
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
    Waiting: sym:waiting
    Rework: sym:rework
    Reworking: sym:reworking
    Merging: sym:merging
    Done: sym:done
    Canceled: sym:canceled
    Duplicate: sym:duplicate
state_manager:
  mode: authoritative
  # journal_path defaults to the workflow-scoped path under the host XDG state directory.
  human_intent_labels:
    Planned: sym:request-planned
    Rework: sym:request-rework
    Merging: sym:request-merging
    Human Review: sym:request-human-review
    Canceled: sym:request-canceled
    Duplicate: sym:request-duplicate
    Reopen: sym:request-reopen
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
    bash ./scripts/worktree-bootstrap.sh copy-env
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

    if ! command -v pnpm >/dev/null 2>&1; then
      printf "ERROR: cannot clean Myven workspace; pnpm command not found\n" >&2
      exit 127
    fi

    if ! command -v docker >/dev/null 2>&1; then
      printf "WARN: skipped Myven compose cleanup; docker command not found\n" >&2
      exit 0
    fi

    printf "INFO: stopping Myven local stack for %s\n" "$workspace_root"
    if ! pnpm local:down; then
      printf "ERROR: pnpm local:down failed for %s\n" "$workspace_root" >&2
      exit 1
    fi

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
  max_turns: 7
  max_review_verdicts: 3
  orchestration_brief_enabled: true
  review_states:
    - Review
    - Reviewing
  rework_state: Rework
  reworking_state: Reworking
  human_review_state: Human Review
  dispatch_kinds:
    - issue
    - pull_request
  source_checkout_states:
    - Todo
codex:
  command: codex app-server
  task_profiles:
    orchestration:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=medium app-server
      model: gpt-5.6-terra
      effort: medium
    planning:
      command: codex --config 'model="gpt-5.6-sol"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-sol
      effort: high
    exploration:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=medium app-server
      model: gpt-5.6-terra
      effort: medium
    single_file_edit:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-terra
      effort: high
    bug_with_test_log:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-terra
      effort: high
    unknown_bug:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-terra
      effort: high
    multi_file_refactor:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-terra
      effort: high
    review:
      command: codex --config 'model="gpt-5.6-sol"' --config model_reasoning_effort=xhigh app-server
      model: gpt-5.6-sol
      effort: xhigh
    feature_without_tests:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=high app-server
      model: gpt-5.6-terra
      effort: high
    default:
      command: codex --config 'model="gpt-5.6-terra"' --config model_reasoning_effort=medium app-server
      model: gpt-5.6-terra
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
verification:
  full_states:
    - Merging
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
| 계획/기획 | `gpt-5.6-sol` + `high` effort |
| 리뷰/검토 | `gpt-5.6-sol` + `xhigh` effort |
| 탐색/조사/분석 | `gpt-5.6-terra` + `medium` effort |
| 구현(단일 파일, 버그 수정, 리팩터, 기능 추가) | `gpt-5.6-terra` + `high` effort |

Instructions:
1. Symphony is the only workflow-state authority. You may read GitHub state and feedback, but you MUST NOT add or remove any `sym:*` label, create automated issue/PR comments or reviews, edit issue/PR bodies, close or reopen an item, create a tracker item, or merge a pull request. Return a semantic outcome and let Symphony's broker perform the tracker effects.
2. Canonical labels are `sym:todo`, `sym:planned`, `sym:in-progress`, `sym:review`, `sym:reviewing`, `sym:human-review`, `sym:waiting`, `sym:rework`, `sym:reworking`, `sym:merging`, `sym:done`, `sym:canceled`, and `sym:duplicate`. Human operators request changes with `sym:request-*` labels; workers MUST NOT apply those request labels either.
3. Keep changes scoped and minimal. Prefer safe, deterministic changes and record repository-local implementation notes only when the current lane permits repository edits.
4. If Codex goal support is available, create exactly one active goal for the current tracker-state objective. The goal is a scope guard, not permission to expand work or mutate tracker state. Complete it after the repository work and verification required for the semantic outcome are finished.
5. Do not spawn supervisor agents in this unattended run. For implementation runs, perform the required self-review yourself. For Review or Reviewing, perform general code review only; dedicated security review requires an explicit human request.
6. Do not call tools that require interactive MCP elicitation or human input. Return `blocked` if no non-interactive path exists.
   - Non-interactive headless Playwright is allowed for deterministic local checks.
   - Repo-local Playwright/E2E commands may need `sandbox_permissions=require_escalated` on macOS. Retry a `MachPortRendezvousServer`, `bootstrap_check_in`, Crashpad, or `Permission denied (1100)` failure once with that permission before treating it as an application failure.
7. For local URLs and browser/smoke verification, read the current worktree's `.env.local` and use its `MYVEN_*_PORT` values; do not assume default ports are free.
8. Tracker-facing summaries, proposed issue/PR bodies, titles, and findings returned to Symphony must be Korean unless quoting source text or preserving an external title.
9. Todo items are planning-only. Do not create, modify, commit, or push repository files, including `docs/draft/*`. Analyze the item and return `planning_complete` with a Korean summary and PR-sized proposals in `evidence`.
10. Planned and In Progress items are implementation lanes, regardless of whether the tracker item is an issue or pull request. Implement only the approved change and return `implementation_complete`; Symphony's control path remains the only writer for issue/PR topology, bodies, links, labels, source-issue handoff, and pull-request branch publication. For pull-request work, commit locally in the detached worktree but do not push; return the exact detached HEAD OID so Symphony's broker can verify and publish it.
    - Preserve explicit PR1/PR2 sections. Split child branches target an issue feature branch; the feature-to-main integration PR is the only PR that closes the source issue.
    - Default split execution is sequential unless the issue explicitly requests parallel execution.
    - Native GitHub sub-issues remain the unit of implementation and close only their own child issue.
11. If an issue already has an open linked implementation PR, do not duplicate repository work in the issue lane. Return `implementation_complete` with the linked PR status and recommended source-issue handoff. A waiting feature-to-main integration PR does not block the next explicitly requested child PR.
12. Planned pull requests run after Symphony projects `In Progress`. Run focused verification, complete the self-review checklist, commit the approved changes locally, and return `implementation_complete`. Include the exact detached HEAD OID, commands/results, and the Korean transition summary; Symphony's broker verifies and publishes the commit before moving the PR to Review and keeping the source issue in Human Review.
13. Review pull requests run after Symphony projects `Reviewing`. Review only. Return `clean_review` when no required improvement exists, or `review_findings` with actionable findings. Symphony applies Human Review or Rework according to the review-verdict budget and synchronizes the source issue.
14. Rework pull requests run after Symphony projects `Reworking`. Use the orchestration brief's live head, top-level comments, review summaries, inline review comments, and unresolved threads as the tracker snapshot for the dispatch; do not query or mutate GitHub. Address only actionable feedback, commit the result locally in the detached worktree, and return `rework_complete` with the exact detached HEAD OID. Do not push: Symphony's broker compares the worker commit with the live PR head, performs a verified non-force publish or deterministic integration, and hands off only when that integration needs human judgment.
15. An inline-comment webhook is a rework signal, not proof that a code change is needed. A justified no-change result still returns `rework_complete` with the evidence Symphony should publish.
16. If implementation becomes too large, stop before committing and return `handoff_required` with the Korean split proposal: "이 PR은 너무 커졌으므로 여기까지 commit하지 않고 분할 제안".
17. Merging is an approved verification lane. Use the existing workspace and branch, fetch `origin/main`, rebase it onto the fetched `origin/main`, and inspect changed user-facing text for i18n compliance. A PR is broad-scope when its diff or rebase-conflict resolution touches two or more stable work units, a shared package or repository-wide configuration, a generated API contract, a schema or migration, CI/local-stack tooling, or runtime/deployment infrastructure. A broad-scope PR MUST pass this full local verification bundle after the rebase and before returning `merge_ready`:
    ```bash
    pnpm test
    pnpm --filter @myven/observability test
    CI=true pnpm api:test
    pnpm check
    pnpm build
    pnpm codegen:check
    pnpm local:up
    pnpm local:seed
    pnpm local:smoke
    pnpm e2e:install
    pnpm e2e
    ```
    `pnpm test` omits the observability workspace, so its separate test command is required. `pnpm e2e` is the full Playwright suite and MUST NOT be replaced with targeted smoke coverage for a broad-scope PR. Do not query GitHub or merge. If any required command cannot run or fails, return `blocked` with the command and evidence; do not return `merge_ready` from partial local evidence. Otherwise return `merge_ready` with the exact head OID when local merge preconditions pass; Symphony validates required CI, performs the pinned merge, and projects Done after observing success.
18. Before Merging, other lanes run only focused verification and use any CI snapshot supplied by the orchestration brief without polling GitHub. Do not expand into full API/Web/OpenAPI/Astro suites, Compose startup, seed, or browser setup unless the exact change cannot be verified more narrowly. Retry a plausible environment failure at most once, then report partial evidence.
19. Human Review and Waiting are inactive retention/coordination states and must not execute work. Cleanup is allowed only after Done, Canceled, or Duplicate.
20. Preserve `docs/draft` workpads through Human Review. Before returning `merge_ready`, either move durable content into `docs/architecture`, `docs/design-system`, or `docs/adr`, or remove the draft-only workpad.
21. The orchestration preflight owns the long conductor, review, and GitHub-review reference reading. Its output is an evidence snapshot only: it MUST NOT redefine the worker's execution lane, write authority, allowed scope, tracker transition, or semantic outcome. Symphony derives those fields from the dispatched tracker item. Do not reopen those documents unless the brief names a missing, task-critical reference.
22. Return `blocked` for a retryable external/environment blocker and `handoff_required` when human judgment, scope split, stale head, or exhausted safe retry requires intervention. Do not invent a target state.

Final output contract:

- Return exactly one structured object matching the runtime output schema; do not wrap it in Markdown.
- `outcome` MUST be one of `planning_complete`, `implementation_complete`, `rework_complete`, `clean_review`, `review_findings`, `merge_ready`, `blocked`, or `handoff_required`.
- `head_oid` is the observed Git head for pull-request work and `null` for issue-only planning.
- `evidence` is a list of concise checks, findings, artifacts, or proposed tracker content.
- `summary_ko` is the Korean comment/body summary Symphony may publish with its idempotency marker.
- Never include a target state or target label in the output.
