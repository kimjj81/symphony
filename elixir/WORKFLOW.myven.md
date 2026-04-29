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

    if [ -f .env.local ] && ! grep -q '^COMPOSE_PROJECT_NAME=' .env.local; then
      printf '\nCOMPOSE_PROJECT_NAME=myven_%s\n' "$(printf '%s' "$SYMPHONY_ISSUE_IDENTIFIER" | tr -c 'A-Za-z0-9_' '_')" >> .env.local
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
8. If this item is a GitHub issue in Todo, do not implement code. Analyze the issue, propose PR-sized work items in a GitHub comment, then move the item to Human Review.
9. If this item is a GitHub issue in In Progress, create or update PR-sized implementation work and keep the issue comment trail current.
10. If this item is a pull request in Todo, improve the PR description, implementation plan, and validation plan, then move it to Human Review.
11. If this item is a pull request in Planned, move it to In Progress, implement the approved change, run the narrowest useful validation, comment with results, then move it to Human Review.
12. If this item is in Rework, read the latest GitHub review comments and issue/PR comments first, address only the requested follow-up changes, comment with results, then move it to Human Review.
13. Do not continue working after moving the item to Human Review.
