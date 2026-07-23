# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear, GitHub, or Forgejo for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt and structured semantic-outcome schema to Codex
5. Serializes the outcome through Symphony's state manager and projects one verified tracker state

During app-server sessions, Symphony may serve a read-only client-side `linear_graphql` tool. Tracker
state changes and automated comments use Symphony's broker and are not exposed to worker sessions.

Workers do not add/remove `sym:*` labels, close/reopen items, publish automated transition comments,
or merge pull requests. They return a semantic outcome plus head OID, evidence, and a Korean summary.
The state manager journals and validates the transition before the tracker broker applies it.

The Elixir contract is `SymphonyElixir.StateManager.request/1` (or `/2` for an explicit server) with
`SymphonyElixir.TransitionIntent`. It returns `{:ok, %AppliedTransition{}}`, `{:noop, reason}`,
`{:conflict, snapshot}`, `{:rejected, reason}`, or `{:error, reason}`. Worker output is decoded into a
`SymphonyElixir.TransitionWorkerOutcome` before any transition request is made.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - Worker sessions may use Symphony's `linear_graphql` app-server tool for scoped reads. Mutations,
     including comments and state changes, go through Symphony's broker.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Reviewing", "Rework", "Reworking", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_review_verdicts: 3
  dispatch_kinds:
    - issue
    - pull_request
state_manager:
  mode: authoritative
codex:
  command: codex app-server
notifications:
  discord:
    enabled: false
    webhook_url: $DISCORD_WEBHOOK_URL
    notify_states:
      - Human Review
      - Done
      - Canceled
      - Cancelled
      - Closed
      - Duplicate
  cmux:
    enabled: false
    command: cmux
    notify_states:
      - Human Review
      - Done
      - Canceled
      - Cancelled
      - Closed
      - Duplicate
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `state_manager.mode` supports `legacy`, `shadow`, and `authoritative`; never run legacy and
  authoritative writers together. New production workflows should explicitly select
  `authoritative`.
- `state_manager.journal_path` defaults to
  `${XDG_STATE_HOME:-~/.local/state}/symphony/<workflow-path-hash>/transitions.log`.
- GitHub and Forgejo workflows configure `state_manager.human_intent_labels` so operators can request changes
  with temporary labels. Direct edits to canonical workflow labels are reconciled as drift.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- `codex.auto_approve_requests: true` makes Symphony approve app-server approval requests without
  operator input. Use this only when the workflow is externally sandboxed enough for broad
  auto-approval.
- `codex.auto_approve_command_patterns` is a narrower non-interactive path for unattended runs.
  When `codex.approval_policy` is `on-request`, Symphony approves command-execution approval
  requests whose command text contains one of these patterns and leaves other approval requests
  blocked. This is useful for browser E2E commands that must run outside the Codex sandbox on
  macOS, such as Playwright smoke tests that otherwise fail before page load with Mach service
  permission errors.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_review_verdicts` caps automatic `review_findings -> Rework` cycles in briefed runs.
  Symphony performs one confirmation review after the configured cycles; a further finding enters
  Human Review instead of starting another automatic rework. Default: `3`.
- `agent.dispatch_kinds` limits which tracker item kinds can dispatch Codex workspace runs.
  Supported values are `issue` and `pull_request`; the default is both. Keep `issue` enabled
  when Todo GitHub issues should run planning-only Codex turns that leave tracker comments.
  Use `["pull_request"]` when issues should remain a manual planning/control surface and only PRs should create workspaces.
  GitHub issue control actions, such as opening a PR from a Planned issue, can still run without
  creating a Codex workspace for the source issue.
- `agent.source_checkout_states` lists issue states that should run from the configured
  `workspace.source` checkout instead of creating a per-issue workspace. Use this for planning-only
  states such as GitHub `Todo` when the agent should review the latest `main` tree and leave only
  tracker comments. Source-checkout runs require the source checkout to be on the branch implied by
  `workspace.base_ref` and clean; Symphony updates it with `git pull --ff-only origin <branch>` and
  starts Codex with a read-only sandbox.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.kind: forgejo` requires a Forgejo v16 API endpoint ending in `/api/v1`, plus `owner` and
  `repo`. Use separate `SYMPHONY_TRACKER_READ_TOKEN` and `SYMPHONY_TRACKER_WRITE_TOKEN` values when
  possible. `FORGEJO_TOKEN` remains a legacy write-token fallback. The write token needs
  `write:issue` and `write:repository`; Codex workers never inherit it.
  When `write_api_key` uses a custom `$VAR`, Symphony also strips that source variable from workers.
  The standalone daemon starts Codex with a narrow environment allowlist, so custom write-token
  source variables cannot be inherited either.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.6-terra\"' app-server"
```

Forgejo example:

```yaml
tracker:
  kind: forgejo
  endpoint: https://forgejo.example.org/api/v1
  owner: example
  repo: project
  read_api_key: $SYMPHONY_TRACKER_READ_TOKEN
  write_api_key: $SYMPHONY_TRACKER_WRITE_TOKEN
  bot_login: symphony
```

Copy `WORKFLOW.forgejo.md` as a starting point for a complete provider-specific workflow.

Forgejo child issues use one `sym:parent-<number>` label, such as `sym:parent-42`. Symphony treats
multiple or malformed parent labels as a conflict, preserves the relationship label during state
projection, blocks terminal parents with unfinished children, completes a parent after its final
terminal child, and uses it for Planned-child PR delegation.

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `notifications.discord` can send state-transition alerts to a Discord channel through a webhook.
  Keep the webhook secret in an environment variable such as `DISCORD_WEBHOOK_URL`; by default
  Discord notifications are disabled and notify on `Human Review` plus terminal states.
- `notifications.cmux` can send the same state-transition alerts to cmux with `cmux notify`.
  Run Symphony from a cmux terminal so `CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, and
  `CMUX_SURFACE_ID` are inherited, or set `command` to the cmux CLI path. By default cmux
  notifications are disabled and notify on `Human Review` plus terminal states when enabled.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, `/api/v1/refresh`, and
  `/api/v1/github/webhook`.
- `POST /api/v1/github/webhook` accepts GitHub `issues`, `pull_request`,
  `pull_request_review`, and `issue_comment` events. Set `SYMPHONY_GITHUB_WEBHOOK_SECRET` so
  Symphony can verify `X-Hub-Signature-256` before queueing an immediate refresh. For GitHub tracker
  workflows, labeled and pull-request closed events are queued as immutable intents or facts. The
  webhook handler does not change labels directly; the state manager validates the event before the
  broker projects state.
- `POST /api/v1/forgejo/webhook` accepts the equivalent Forgejo events. Set
  `SYMPHONY_FORGEJO_WEBHOOK_SECRET`; Symphony validates the raw hexadecimal HMAC-SHA256 value in
  `X-Forgejo-Signature` and reads `X-Forgejo-Event` plus `X-Forgejo-Delivery`. Forgejo webhook
  support is direct HTTP only; the signed payload repository must match configured `owner/repo`.
  Head updates and review submissions are refresh-only events. Reopens are brokered transition
  requests that converge to `Human Review`, then schedule a targeted refresh. The GitHub NATS relay
  remains unchanged.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

For the Myven workflow, `scripts/run_myven.sh` can register GitHub webhooks against the fixed
Oracle relay endpoint used by the local consumers:

```bash
SYMPHONY_GITHUB_WEBHOOK_MODE=ghook \
SYMPHONY_GITHUB_WEBHOOK_URL=https://ghook.windroamer.com/github \
./scripts/run_myven.sh
```

The script stores the reusable webhook secret under
`$HOME/.config/symphony/myven-github-webhook-secret` and the GitHub hook id under
`$HOME/.cache/symphony/myven-github-webhook-id`. Without `SYMPHONY_GITHUB_WEBHOOK_MODE`, it keeps the
normal local polling path. `SYMPHONY_GITHUB_WEBHOOK_MODE=ngrok` remains available for local direct
Phoenix API experiments, but should not be used for Myven's fixed relay setup.

The fixed relay publishes GitHub deliveries to NATS for local consumers such as Hermes Kanban and
Symphony itself. Enable Symphony's opt-in NATS consumer with its own durable consumer name so it does
not compete with Hermes Kanban:

```bash
SYMPHONY_NATS_WEBHOOK_ENABLED=true
SYMPHONY_NATS_URL=nats://100.77.171.83:24222
SYMPHONY_NATS_STREAM=GITHUB_WEBHOOKS
SYMPHONY_NATS_DURABLE=symphony-webhook
SYMPHONY_NATS_SUBJECT=github.webhook.*
```

NATS messages are fed through the same GitHub webhook processor used by `/api/v1/github/webhook`, so
labels/comments/reviews trigger the same GitHub state sync and targeted orchestrator refreshes.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
