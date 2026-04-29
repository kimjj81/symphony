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
    - Rework
  terminal_states:
    - Human Review
    - Merging
    - Done
    - Canceled
    - Duplicate
  state_labels:
    Todo: sym:todo
    Planned: sym:planned
    In Progress: sym:in-progress
    Human Review: sym:human-review
    Rework: sym:rework
    Merging: sym:merging
    Done: sym:done
    Canceled: sym:canceled
    Duplicate: sym:duplicate
polling:
  interval_ms: 8000
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

    if [ -f infra/local/docker-compose.yml ]; then
      perl -0pi -e 's/"8080:80"/"\${MYVEN_GATEWAY_PORT:-8080}:80"/g;
        s/"4317:4317"/"\${MYVEN_OTEL_GRPC_PORT:-4317}:4317"/g;
        s/"4318:4318"/"\${MYVEN_OTEL_HTTP_PORT:-4318}:4318"/g;
        s/"13133:13133"/"\${MYVEN_OTEL_HEALTH_PORT:-13133}:13133"/g;
        s/"8888:8888"/"\${MYVEN_OTEL_METRICS_PORT:-8888}:8888"/g;
        s/"4999:4321"/"\${MYVEN_WEB_PORT:-4999}:4321"/g;
        s/"8000:8000"/"\${MYVEN_API_PORT:-8000}:8000"/g;
        s/"8100:8100"/"\${MYVEN_WEBHOOKS_PORT:-8100}:8100"/g;
        s/"5433:5432"/"\${MYVEN_POSTGRES_PORT:-5433}:5432"/g;
        s/"4566:4566"/"\${MYVEN_LOCALSTACK_PORT:-4566}:4566"/g;
        s/"1025:1025"/"\${MYVEN_MAILPIT_SMTP_PORT:-1025}:1025"/g;
        s/"8025:8025"/"\${MYVEN_MAILPIT_UI_PORT:-8025}:8025"/g;
        s#http://app\.myven\.localhost:8080#http://app.myven.localhost:\${MYVEN_GATEWAY_PORT:-8080}#g;
        s#http://myven\.localhost:8080#http://myven.localhost:\${MYVEN_GATEWAY_PORT:-8080}#g;
        s#http://127\.0\.0\.1:4999#http://127.0.0.1:\${MYVEN_WEB_PORT:-4999}#g;
        s#http://localhost:4999#http://localhost:\${MYVEN_WEB_PORT:-4999}#g;
        s#http://127\.0\.0\.1:4566#http://127.0.0.1:\${MYVEN_LOCALSTACK_PORT:-4566}#g;' \
        infra/local/docker-compose.yml
    fi

    [ -f .env.local ] || : > .env.local

    compose_project_suffix="$(printf '%s' "$SYMPHONY_ISSUE_IDENTIFIER" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')"
    compose_project_name="myven_${compose_project_suffix}"
    awk -v value="$compose_project_name" '
      BEGIN { found = 0 }
      /^COMPOSE_PROJECT_NAME=/ { print "COMPOSE_PROJECT_NAME=" value; found = 1; next }
      { print }
      END { if (!found) print "COMPOSE_PROJECT_NAME=" value }
    ' .env.local > .env.local.tmp && mv .env.local.tmp .env.local

    random_port_base="$(awk -v seed="$(date +%s)$$" 'BEGIN { srand(seed); print int(50000 + rand() * 9000) }')"
    append_port_var() {
      name="$1"
      offset="$2"
      if ! grep -q "^${name}=" .env.local; then
        printf '%s=%s\n' "$name" "$((random_port_base + offset))" >> .env.local
      fi
    }

    append_port_var MYVEN_GATEWAY_PORT 0
    append_port_var MYVEN_WEB_PORT 1
    append_port_var MYVEN_API_PORT 2
    append_port_var MYVEN_WEBHOOKS_PORT 3
    append_port_var MYVEN_POSTGRES_PORT 4
    append_port_var MYVEN_LOCALSTACK_PORT 5
    append_port_var MYVEN_MAILPIT_SMTP_PORT 6
    append_port_var MYVEN_MAILPIT_UI_PORT 7
    append_port_var MYVEN_OTEL_GRPC_PORT 8
    append_port_var MYVEN_OTEL_HTTP_PORT 9
    append_port_var MYVEN_OTEL_HEALTH_PORT 10
    append_port_var MYVEN_OTEL_METRICS_PORT 11
  before_remove: |
    :
agent:
  max_concurrent_agents: 2
  max_turns: 3
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write

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
4. Use the GitHub labels as the state machine: sym:todo, sym:planned, sym:in-progress, sym:human-review, sym:rework, sym:merging, sym:done, sym:canceled, sym:duplicate.
5. Do not spawn sub-agents, supervisor agents, reviewer agents, or specialist agents in this unattended Symphony run.
6. If repository instructions require supervisor/reviewer agents, treat Symphony as the supervisor and perform a concise self-review instead.
7. Do not call tools that require interactive MCP elicitation or human input; record the blocker and stop if no non-interactive path exists.
8. Write GitHub issue comments, issue bodies, pull request titles, pull request descriptions, and pull request comments in Korean unless quoting source text or preserving an existing external title.
9. If this item is a GitHub issue in Todo, do not implement code. Analyze the issue, propose PR-sized work items in a GitHub comment, then move the item to Human Review.
10. If this item is a GitHub issue in Planned, treat Planned as explicit human approval to execute. Move it to In Progress, implement the approved scope, open or update one PR, comment with validation results, then move it to Human Review.
11. Symphony must not move a GitHub issue from Todo or Human Review to Planned by itself. Only a human-applied sym:planned label is an approval gate.
12. If a Planned issue is explicitly a planning/splitting issue, create the requested PR-sized follow-up issues instead of changing product code. Label follow-up implementation issues sym:planned only when the parent issue explicitly asks for immediate execution; otherwise label them sym:todo for human review.
13. If this item is a GitHub issue in In Progress, create or update PR-sized implementation work and keep the issue comment trail current.
14. If this item is a pull request in Todo, improve the PR description, implementation plan, and validation plan, then move it to Human Review.
15. If this item is a pull request in Planned, move it to In Progress, implement the approved change, run the narrowest useful validation, comment with results, then move it to Human Review.
16. If this item is in Rework, read the latest GitHub review comments and issue/PR comments first, address only the requested follow-up changes, comment with results, then move it to Human Review.
17. Do not continue working after moving the item to Human Review.
