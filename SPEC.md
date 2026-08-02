# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear, GitHub, or Forgejo), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is the sole automated authority for tracker workflow state.
- Coding agents report semantic outcomes; they MUST NOT select or write target workflow states.
- Symphony serializes transition intents, records required effects durably, and projects the verified
  state to the tracker through a broker.
- Human-authored comments remain unrestricted. Human GitHub state changes enter Symphony as explicit
  request-label events; other adapters provide an equivalent explicit operator intent. Every intent
  is validated before the canonical state is changed.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Maintain one authoritative workflow-state policy and one serialized automated tracker writer.
- Preserve tracker-visible execution states while preventing stale outcomes from regressing newer or
  terminal states.
- Replay incomplete tracker effects after restart from a durable transition journal.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support journal/tracker/filesystem-driven restart recovery without requiring an external database;
  exact in-memory scheduler and live session state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- General-purpose workflow automation beyond the transition policy configured for the current
  workflow.
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.
   - Applies broker-requested comments and state projections without deciding transitions.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Serializes all transition intents through its mailbox.
   - Tracks session metrics and retry queue state.

5. `Workflow State Policy and Manager`
   - Converts observed state plus semantic intent into a pure transition decision.
   - Writes transition phases to a durable journal before external effects.
   - Invokes the tracker broker and verifies the resulting projection.

6. `Tracker Broker`
   - Owns every automated tracker write, including transition comments, close/reopen, and merge.
   - Applies idempotency markers, expected-state checks, and read-after-write verification.

7. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

8. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.
   - Decodes a structured semantic outcome; it does not mutate tracker state.

9. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

10. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific intent-to-transition policy, validation, and handoff rules.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation, and serialized state
     intents.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (tracker adapter + broker)
   - Read normalization and policy-free application of verified tracker effects.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear and GitHub adapter profiles).
- Local filesystem for workspaces, logs, and the durable transition journal.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

#### 4.1.9 Transition Intent

Immutable request evaluated by the workflow state policy.

Fields:

- `id` (stable transition ID)
- `issue_id`
- `source` and `actor`
- `expected_state`
- `kind` (semantic worker outcome, operator request, or external tracker fact)
- `causation_id` (delivery ID, run ID, or other replay-stable identifier)
- `head_oid` (OPTIONAL; REQUIRED for head-sensitive PR transitions)
- `summary` and `evidence` (OPTIONAL structured worker output)

#### 4.1.10 Transition Plan and Applied Transition

`WorkflowStatePolicy` returns a pure `TransitionPlan` containing the validated source state, target
state, required comment, tracker effects, and no-op or rejection reason. It performs no network or
filesystem I/O.

After the effects are verified, `StateManager` returns an `AppliedTransition` containing the
transition ID, previous and effective states, verified tracker snapshot, and journal position. The
public `StateManager.request(intent)` result is one of:

```text
{:ok, AppliedTransition}
{:noop, reason}
{:conflict, current_snapshot}
{:rejected, policy_reason}
{:error, transport_reason}
```

#### 4.1.11 Transition Journal Record

Durable append-only record keyed by transition ID and causation ID.

Fields:

- `transition_id`, `issue_id`, `causation_id`
- `intent` and `decision`
- `phase`: `received`, `decided`, `required_comment_applied`, `projection_applied`, `verified`, or
  `retrying`
- `attempt`, `error`, and timestamps
- verified tracker snapshot when available

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Design note:

- `WORKFLOW.md` SHOULD be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`
- `notifications`
- `state_manager`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported values: `linear`, `github`, `forgejo`, `asana`, `jira`, `gitlab`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `read_api_key`, `write_api_key` (strings)
  - OPTIONAL split credentials for hosted-Git trackers. Broker writes MUST use `write_api_key` when
    present; workers MAY receive only `read_api_key`.
  - For Forgejo, `api_key` and `FORGEJO_TOKEN` are compatibility write-token fallbacks.
  - If a write key is configured as `$VAR_NAME`, the broker MUST remove `VAR_NAME` as well as the
    canonical write-token variables from every worker environment.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
- `owner`, `repo` (strings)
  - REQUIRED for dispatch when `tracker.kind == "github"` or `tracker.kind == "forgejo"`.
- `state_labels` (map `state_name -> label`)
  - REQUIRED when tracker-native workflow state is represented by hosted-Git labels.
  - Canonical state labels MUST be disjoint from `state_manager.human_intent_labels`.
- `provider` (map)
  - Provider-native settings for Asana, Jira, and GitLab.
  - These providers are supported only when `state_manager.mode == "legacy"`.
- `required_labels` (list of strings)
  - OPTIONAL case-insensitive labels that every dispatch candidate MUST contain.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `WORKFLOW.md`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure or timeout aborts deletion and is returned to the caller so terminal cleanup can retry.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `notifications` (object)

Optional operator notification sinks.

Fields:

- `discord` (object)
  - `enabled` (boolean), default `false`.
  - `webhook_url` (string), MAY be a literal URL or `$VAR_NAME`.
  - `notify_states` (list of strings), default `Human Review`, `Done`, `Canceled`, `Cancelled`,
    `Closed`, `Duplicate`.
  - Implementations SHOULD send Discord notifications when a running issue transitions into one of
    the configured states.
  - Notification delivery failures SHOULD be logged and MUST NOT fail orchestration.

#### 5.3.6 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_review_verdicts` (positive integer)
  - Default: `3`.
  - Limits automatic `review_findings -> Rework` cycles in a briefed worker run. After the
    configured number of rework cycles, Symphony runs one confirmation review: a clean result
    enters `Human Review`, while another finding is handed to `Human Review` without another
    automatic rework.
- `orchestration_brief_enabled` (boolean)
  - Default: `false` for backward compatibility.
- `review_states` (list of strings), `rework_state` (string), `reworking_state` (string),
  `human_review_state` (string)
  - Define the transition-aware review cycle without hard-coding tracker labels.
  - `reworking_state` defaults to `Reworking` and is the tracker-visible execution state entered
    before dispatching rework.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.

#### 5.3.7 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `task_profiles.orchestration`
  - Selects the model, effort, and command for the read-only preflight agent.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
- `auto_approve_requests` (boolean or null)
  - Default: implementation-defined.
  - When true, the runtime MAY approve app-server approval requests without
    operator input. Use only for workflows whose external execution boundary is
    already trusted enough for broad approval.
- `auto_approve_command_patterns` (list of strings)
  - Default: `[]`.
  - When non-empty, the runtime MAY approve command-execution approval requests
    whose command text contains one of the configured strings. This is intended
    for narrow unattended approvals, such as browser E2E commands that need to
    run outside a local sandbox.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

#### 5.3.8 `state_manager` (object)

Fields:

- `mode` (`legacy | shadow | authoritative`)
  - Default: `legacy` for workflows created before this contract.
  - New production workflows SHOULD explicitly select `authoritative`.
  - `legacy` enables the previous writer and disables state-manager effects.
  - `shadow` evaluates and journals intents while the single legacy writer applies the transition;
    the new broker performs no tracker write.
  - `authoritative` enables the broker and MUST disable all legacy automated writers.
  - Implementations MUST NOT run legacy and authoritative writes concurrently.
- `journal_path` (path string or `$VAR`, OPTIONAL)
  - Default:
    `${XDG_STATE_HOME:-~/.local/state}/symphony/<workflow-path-hash>/transitions.log`.
  - The path is normalized outside the repository and workspace roots.
  - Only one process may hold the workflow journal; lock acquisition failure MUST fail closed.
- `human_intent_labels` (map `state_or_action -> label`, OPTIONAL)
  - REQUIRED for an authoritative GitHub workflow that exposes label-based operator requests.
  - Maps `Planned`, `Rework`, `Merging`, `Human Review`, `Canceled`, `Duplicate`, and `Reopen` to
    temporary operator request labels.
  - `Reopen` targets `Human Review` and is the only request allowed to leave a terminal state.
  - Request labels MUST NOT be treated as canonical workflow-state labels.

The tracker write credential is supplied to the host as `SYMPHONY_TRACKER_WRITE_TOKEN`; it MUST be
resolved only by the broker and MUST NOT be included in the coding-agent environment.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse YAML front matter into a raw config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the directory containing the selected
  `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- On change, it MUST re-read and re-apply workflow config and prompt template without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when REQUIRED by the selected tracker kind.
- `codex.command` is present and non-empty.
- `state_manager.mode` is recognized and authoritative mode has a writable, exclusively lockable
  journal location plus broker-only write credentials.
- Canonical and request label maps are disjoint and contain all states/actions required by policy.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, currently `linear`, `github`, `forgejo`, `asana`, `jira`, or `gitlab`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when `tracker.kind=linear`
- `tracker.read_api_key`, `tracker.write_api_key`: optional split hosted-Git credentials
- `tracker.project_slug`: string, REQUIRED when `tracker.kind=linear`
- `tracker.owner`, `tracker.repo`: strings, REQUIRED when `tracker.kind=github` or `tracker.kind=forgejo`
- `tracker.endpoint`: MUST end in `/api/v1` when `tracker.kind=forgejo`; Forgejo major version 16 is supported
- `tracker.bot_login`: optional tracker actor login used to recognize broker projection webhook echoes
- `tracker.state_labels`: canonical state-to-label map for GitHub and Forgejo
- `tracker.provider`: provider-native Asana, Jira, or GitLab settings; these providers require legacy mode
- `tracker.required_labels`: optional case-insensitive dispatch label filter
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_review_verdicts`: integer, default `3`
- `agent.orchestration_brief_enabled`: boolean, default `false`
- `agent.review_states`: list of strings, default `["Review", "Reviewing"]`
- `agent.rework_state`: string, default `Rework`
- `agent.reworking_state`: string, default `Reworking`
- `agent.human_review_state`: string, default `Human Review`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `codex.command`: shell command string, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.auto_approve_requests`: boolean or null, default implementation-defined
- `codex.auto_approve_command_patterns`: list of strings, default `[]`
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`
- `state_manager.mode`: `legacy | shadow | authoritative`, default `legacy`
- `state_manager.journal_path`: path or `$VAR`, default under the host XDG state directory
- `state_manager.human_intent_labels`: map of human state/action names to request labels
- `verification.full_states`: list of strings, default `["Merging"]`

## 7. Orchestration and Workflow State Machines

The orchestrator owns both scheduling state and serialized workflow transition intents. Scheduling
state remains in memory. Canonical workflow decisions and their external effects are written to a
durable journal and projected to the tracker by the broker. No worker, webhook handler, or tracker
adapter may independently decide or apply an automated workflow transition.

### 7.1 Issue Orchestration States

This is not the same as canonical tracker states (`Todo`, `In Progress`, etc.). This is the service's
internal claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker produces exactly one structured outcome per turn. An implementation MAY retain the
  app-server process for another turn only after the state manager accepts the outcome and explicitly
  authorizes continuation in the effective state.
- After each normal turn completion, the worker returns a semantic outcome to the orchestrator.
- The state manager re-checks current state, evaluates that outcome, and decides whether another turn
  is eligible, up to `agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

Workflows MAY enable orchestration briefs for bounded PR review/rework cycles:

- The broker reads the live PR head, comments, reviews, inline comments, and unresolved feedback
  once per fresh worker turn. GitHub issue comments and nested unresolved-thread comment pages are
  fully paginated. It renders a compact manifest no larger than 8 KiB plus an indexed YAML
  evidence sidecar no larger than 8 MiB. The manifest supplies the sidecar digest, inclusive line
  ranges, and lane-required regions; workers read the immutable sidecar and never query the tracker
  directly.
- The sidecar preserves unresolved threads verbatim and separates human comments, review summaries,
  inline comments, broker worker reports, transition history, and exact-duplicate occurrence
  metadata. Literal bodies preserve leading whitespace and the exact trailing-LF count after LF
  normalization. Top-level review-thread and nested-comment pagination fails the whole snapshot for
  missing, empty, or repeated cursors or malformed page information. The broker compares the parsed
  YAML index with the computed index and validates line ranges, item counts, byte counts, and
  SHA-256 before dispatch.
- If broker snapshot or sidecar generation, transfer, or verification fails or exceeds its limit, no
  worker starts. Retryable failures use the bounded dispatch retry policy; missing authority,
  unsupported providers, stale heads, or an exhausted retry budget hand off to Human Review.
- Each briefed worker turn starts a fresh coding-agent thread and receives only tracker identity,
  the compact manifest, the immutable sidecar, the current review-verdict counter, and the
  verification tier. Continuation turns regenerate both artifacts from current tracker state.
- Briefed continuation is transition-aware rather than based on active state alone. Implementation or
  rework may continue to review; the configured budget permits that many complete automatic
  review/rework cycles. The next review is a confirmation review: a clean review stops immediately
  in Human Review, and remaining findings are handed to Human Review without another rework.
- In legacy briefed runs, `agent.max_turns` MUST allow the configured review/rework cycles plus
  their confirmation review; with the default budget of three, a run starting in implementation
  needs eight turns. Authoritative mode dispatches one turn per state transition and uses the
  transition journal's review counter instead of `agent.max_turns` to preserve the cycle budget.
- When the confirmation review still has findings, or when a worker reports `handoff_required`,
  policy moves the item to Human Review with a brokered handoff comment.
- Full verification and required-CI waiting are reserved for configured full states such as Merging.
  Earlier states run focused checks and inspect CI once without polling.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Submit the structured worker outcome to the state manager.
  - Schedule continuation retry only when the applied transition remains dispatch-eligible.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Codex Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Tracker Webhook Fact`
  - Submit immutable close, merge, review, or projection-echo facts to the state manager.

- `Human Request Label`
  - Re-read live state, validate the requested edge, and either apply it or restore the last verified
    state.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Canonical Workflow States and Outcomes

A tracker item MUST have exactly one canonical configured workflow-state label. Execution phases are
tracker-visible so operators can inspect progress without opening Symphony:

| Trigger or semantic outcome | Required transition |
| --- | --- |
| issue `planning_complete` | workflow-specific control effects, then `Human Review` |
| implementation dispatch | `Planned -> In Progress` |
| `implementation_complete` | `In Progress -> Review` |
| review dispatch | `Review -> Reviewing` |
| `clean_review` | `Reviewing -> Human Review` |
| `review_findings` within automatic rework-cycle budget | `Reviewing -> Rework` |
| `review_findings` in the confirmation review | `Reviewing -> Human Review` |
| rework dispatch | `Rework -> Reworking` |
| `rework_complete` | `Reworking -> Review` |
| `merge_ready` followed by observed successful merge | `Merging -> Done` |
| close without merge | any non-terminal state `-> Canceled` |
| `blocked` or `handoff_required` after retry policy | active execution state `-> Human Review` |

`Todo`, `Planned`, `In Progress`, `Review`, `Reviewing`, `Rework`, `Reworking`, and `Merging` MAY be
active according to workflow configuration. `Human Review` and `Waiting` are inactive retention or
coordination states. `Done`, `Canceled`, and `Duplicate` are terminal and monotonic. A stale outcome
observing a terminal state MUST return a no-op rather than regress it.

A same-state observation that matches the transition's already-applied target is an idempotent no-op,
not a failed worker outcome. Missing or multiple canonical states MUST quarantine the item and MUST
NOT dispatch a worker.

### 7.5 Idempotency and Recovery Rules

- The orchestrator serializes scheduling and workflow-state mutations through one authority.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Before launching a worker, reserve a durable dispatch lease derived from the verified dispatch
  transition. A crash after reservation is fail-closed and MUST NOT launch a second worker.
- Each transition intent MUST have a replay-stable ID and causation ID.
- Before every external effect, `StateManager` synchronously appends the next journal phase:
  `received`, `decided`, `required_comment_applied`, `projection_applied`, `verified`; recoverable
  failures are recorded as `retrying`.
- Required automated comments contain `<!-- sym-transition:<transition-id> -->`. Replay MUST search
  for the marker before creating a comment.
- State projections use an expected-state check and read-after-write verification.
- Reconciliation runs before dispatch on every tick.
- Restart recovery replays incomplete journal records, then reconciles tracker and filesystem state.
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using active states.
4. Sort issues by dispatch priority.
5. Dispatch eligible issues while slots remain.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not dispatch when any blocker is non-terminal.

Sorting order (stable intent):

1. `priority` ascending (1..4 are preferred; null/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.
- Terminal cleanup failures use a separate retry entry with the same exponential failure backoff.
  Before each retry, the tracker state is fetched again: an explicit terminal state retries cleanup,
  an explicit non-terminal state cancels cleanup, and an empty or failed lookup schedules another
  retry. Retries have no attempt limit; only the delay is capped by
  `agent.max_retry_backoff_ms`. Successful cleanup, including an already-absent workspace, clears
  the retry entry.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_codex_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > codex.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, attempt to remove the corresponding workspace directory.
   An already-absent workspace is successful; a hook, remote, or worktree removal failure preserves
   the workspace and schedules terminal cleanup retry without blocking startup.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout aborts workspace deletion and is returned to the caller.
  Terminal cleanup retains the workspace and retries with tracker revalidation and exponential
  backoff.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating a Codex
app-server. The Codex app-server protocol for the targeted Codex version is the source of truth for
protocol schemas, message payloads, transport framing, and method names.

Protocol source of truth:

- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  instead of treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport/framing: the protocol transport required by the targeted Codex app-server version

Notes:

- The default command is `codex app-server`.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the targeted Codex app-server contract. Symphony additionally requires the
client to:

- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start the first turn with the rendered issue prompt.
- Supply an output schema for worker turns that requires one semantic outcome, observed head OID when
  relevant, verification evidence, and a human-readable summary.
- Start later in-worker continuation turns on the same live thread with continuation guidance rather
  than resending the original issue prompt.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client processes app-server updates according to the targeted Codex app-server protocol until
the active turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn on the same
  live thread using the targeted protocol.
- The app-server subprocess SHOULD remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`
- `worker_outcome`

The terminal `worker_outcome` payload MUST validate against the configured output schema. Its
`outcome` is one of `planning_complete`, `implementation_complete`, `rework_complete`,
`clean_review`, `review_findings`, `merge_ready`, `blocked`, or `handoff_required`. The payload MAY
include structured findings, verification evidence, and a Korean tracker-summary body. It MUST NOT
contain a caller-selected target workflow state.

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extensions:

- An implementation MAY expose a limited set of client-side tools to the app-server session.
- Current optional tools are `linear_graphql` and the legacy-only provider tools `asana_api`,
  `jira_rest`, and `gitlab_api`.
- If implemented, supported tools SHOULD be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Codex app-server version.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

`linear_graphql` extension contract:

- Purpose: execute one read-only GraphQL query against Linear using Symphony's configured read
  credential for the current session. Mutations that create transition comments or change workflow
  state MUST go through the tracker broker and MUST be rejected by this worker-facing tool.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL query operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Symphony workflow/runtime config; do
  not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `codex.read_timeout_ms`: request/response timeout during startup and sync requests
- `codex.turn_timeout_ms`: total turn stream timeout
- `codex.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start the app-server session with the semantic-outcome output schema.
4. Forward app-server events to the orchestrator.
5. Validate and return one structured worker outcome after a successful turn.
6. On an app-server error or invalid outcome, fail the worker attempt so the orchestrator can retry
   or hand off. If the semantic outcome was accepted but a broker effect failed, complete the worker
   and retry only the journaled effect with the same transition ID.

The runner MUST NOT infer success from a tracker state reread, call the state projection port, create
an automated transition comment, or map a worker response directly to a target label. All such
effects begin with a `TransitionIntent` submitted to `StateManager`.

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

4. `apply_state_projection(issue_id, expected_state, target_state)`
   - Re-read current tracker state and reject a stale expected state.
   - Preserve non-workflow labels while replacing canonical state and request labels with exactly one
     target-state projection.
   - Perform read-after-write verification.
   - Return `applied`, `already_applied`, `conflict`, or `partial_failure` with the observed snapshot
     or stage-specific error.

5. Broker effect operations
   - Create a comment with an idempotency marker, close/reopen an item, and merge a pull request where
     supported by the selected tracker.
   - These operations MUST be callable only from the state-manager/broker boundary, not from a
     coding-agent session.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.

A non-Linear implementation MAY change transport details, but the normalized outputs MUST match the
domain model in Section 4.

GitHub-specific read and projection semantics are defined by Sections 11.1 and 11.5. GitHub issues
and pull requests share the issue-label API; implementations normalize their configured canonical
state label to the same language-neutral `Issue.state` field used by Linear.

Forgejo-specific requirements for `tracker.kind == "forgejo"`:

- The endpoint MUST end in `/api/v1`; `/version` preflight MUST report major version 16 before
  dispatch. A mismatch skips dispatch but MUST NOT terminate observability or journal recovery.
- IDs MUST be `forgejo:issue:<number>` and `forgejo:pr:<number>`.
- Listing MUST use Forgejo `page`/`limit` pagination and normalize issues plus pull requests.
- State writes MUST resolve numeric label IDs, preserve non-Symphony labels and one valid
  `sym:parent-<number>` relationship label, replace the full set, and verify it.
- Malformed or multiple parent labels are a relationship conflict. Symphony does not infer
  hierarchy from issue text.
- A terminal parent with a non-terminal declared child MUST be projected to Human Review rather
  than closed. When all declared children are terminal, the final child projection MUST
  synchronously converge the parent to Done.
- A parent with declared children but no open Planned child MUST NOT receive a direct PR.
- Only same-repository branches and pull requests are supported; fork and cross-instance PRs fail
  closed.
- Squash merge MUST re-read the PR, compare its head with the expected OID, send `Do: squash` and
  `head_commit_id`, then verify merged/head state. A mergeability-pending response MAY be retried
  only while the pinned head remains unchanged.
- The broker token requires Forgejo `write:issue` and `write:repository` scopes.

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in Section 4.1.1.

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)
- `tracker_projection_conflict`
- `tracker_projection_partial_failure`
- `transition_journal_unavailable`

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal issue fetch failure: log warning and continue startup.
- Per-workspace startup cleanup failure: preserve the workspace, schedule cleanup retry, and continue
  startup.

### 11.5 Tracker Writes (Important Boundary)

Symphony requires first-class tracker write ports owned by the tracker broker.

- `StateManager` is the only component allowed to request an automated workflow projection.
- The broker owns automated transition comments, PR metadata, close/reopen effects, and merges.
- The tracker adapter is transport-only: it applies a requested effect but does not choose the
  target state or parent/sub-item policy.
- Webhook handlers ingest immutable operator intents and external facts. They MUST NOT mutate state
  before the state manager evaluates the event.
- A GitHub state projection MUST begin from a fresh live snapshot, preserve every non-workflow
  label, remove all configured canonical and request labels, add one target label, replace the full
  label set in one request, and verify the result with a second read.
- A Forgejo projection MUST provide the same semantics using Forgejo numeric label IDs.
- Linear projections MUST implement equivalent expected-state, idempotency, and verification
  semantics through its native API.
- A transport success without verified target state is `partial_failure`, not an applied transition.

Human interaction remains part of the tracker UX. Human-authored comments are not brokered. On
GitHub or Forgejo, a person requests a workflow transition by applying one configured
`sym:request-*` label.
The resulting webhook is an intent only; Symphony validates and consumes it. A direct edit of a
canonical state label is drift and is reconciled to the last verified state. Other tracker adapters
MUST expose an explicit, auditable operator-intent mechanism with equivalent validation.

Forgejo HTTP webhooks use `POST /api/v1/forgejo/webhook`, `X-Forgejo-Event`,
`X-Forgejo-Delivery`, and the raw lowercase hexadecimal HMAC-SHA256 value in
`X-Forgejo-Signature`, keyed by `SYMPHONY_FORGEJO_WEBHOOK_SECRET`. Delivery and transition IDs MUST
be provider-qualified. A verified Forgejo delivery MUST also match configured `tracker.owner/repo`
before any intent ingestion or refresh. Head updates and review submissions are refresh-only
intents and MUST still schedule targeted refresh. Reopens are brokered `reopen` transition
requests followed by targeted refresh, so they are projected to `Human Review` rather than silently
changing a canonical state. Journal replay MUST quarantine a
hosted-Git ID whose provider differs from the current tracker before any external write.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.
- State clearly that workers return semantic outcomes and MUST NOT add/remove canonical or request
  workflow labels, close/reopen tracker items, merge pull requests, or publish automated transition
  comments directly.
- State clearly that human-authored comments and request-label input remain tracker-facing operator
  interfaces, while Symphony owns their validation and application.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- `retrying` (list of retry queue rows)
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- The `server` top-level key is owned by this extension.
- Positive `server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads
   - stale expected state or read-after-write projection mismatch
   - partial comment, close/reopen, merge, or projection effect

5. `State Manager Failures`
   - journal lock already held
   - journal append/sync/replay failure
   - missing or multiple canonical states
   - invalid, unauthorized, duplicate, or out-of-order transition intent

6. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Transition journal failures:
  - Stop authoritative tracker writes and new dispatches.
  - Keep the journal for operator recovery; do not fall back to a legacy writer automatically.

- Tracker effect partial failures:
  - Record `retrying` before retry.
  - Re-read comment markers and projection state so an already-applied effect is not duplicated.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Scheduler state remains in memory, while workflow transitions and their effect phases are stored in
the durable journal. Restart recovery means the service can resume useful operation by replaying the
journal, polling tracker state, and reusing preserved workspaces. Retry timers, running sessions, and
live worker state do not survive process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - acquiring the workflow journal's single-writer lock or failing closed
  - replaying non-verified transition records
  - checking comment markers and tracker state before repeating an external effect
  - reconciling verified journal state with the live tracker projection
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work only when no completed or ambiguous durable dispatch lease exists

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes are detected and re-applied automatically without restart according to
  Section 6.2.
- Applying a configured request label in the tracker. The state manager validates the edge and
  applies or rejects the intent; operators SHOULD NOT edit canonical labels directly.
- Inspecting or repairing a quarantined item after missing or multiple canonical state labels are
  reported.
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.
- Resolve `SYMPHONY_TRACKER_WRITE_TOKEN` only in the broker process.
- Remove `GITHUB_TOKEN`, `GH_TOKEN`, `FORGEJO_TOKEN`, `SYMPHONY_TRACKER_WRITE_TOKEN`, and every
  configured `$VAR_NAME` write-token source from worker environments and use an empty worker
  `GH_CONFIG_DIR`. A Forgejo worker MAY receive only the explicitly configured read token.
- Keep repository push credentials separate from tracker API credentials. Operations needing tracker
  write permission, including automated comments and merge, MUST use the broker.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Codex agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Codex approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Codex policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Restricting the worker-facing `linear_graphql` tool to reads inside the intended project scope and
  rejecting state-changing mutations.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  journal = open_and_lock_transition_journal()
  if journal lock failed:
    fail_startup("state manager writer already active")

  replay_incomplete_transitions(journal)
  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)
  state = reconcile_tracker_projections(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  dispatch_result = state_manager.request(dispatch_intent_for(issue))
  if dispatch_result is conflict or rejected or error:
    return release_or_retry_without_worker(state, issue, dispatch_result)

  issue = effective_snapshot(dispatch_result, issue)
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  prompt = build_turn_prompt(workflow_template, issue, attempt)
  if prompt failed:
    app_server.stop_session(session)
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("prompt error")

  turn_result = app_server.run_turn(
    session=session,
    prompt=prompt,
    output_schema=semantic_worker_outcome_schema,
    issue=issue,
    on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
  )

  if turn_result failed or structured_outcome(turn_result) is invalid:
    app_server.stop_session(session)
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent turn or outcome error")

  outcome = structured_outcome(turn_result)

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal(outcome)
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, outcome, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    transition_result = state_manager.request(
      transition_intent_from_worker(running_entry.issue, outcome)
    )

    if transition_result is ok or noop:
      state.completed.add(issue_id)  # bookkeeping only
      if effective_state(transition_result) is dispatch-eligible:
        state = schedule_retry(state, issue_id, 1, {
          identifier: running_entry.identifier,
          delay_type: continuation
        })
      else:
        state.claimed.remove(issue_id)
    else:
      state = release_or_retry_without_projection(state, running_entry, transition_result)
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when OPTIONAL values are missing
- `tracker.kind` validation enforces currently supported kinds (`linear`, `github`, `forgejo`)
- `tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works
- `codex.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts preserve the workspace and surface an
  error for terminal cleanup retry
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states and project slug
- Linear query uses the specified project filter field (`slugId`)
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads
- State projection preserves non-workflow labels and produces exactly one canonical workflow state
- Projection returns applied, already-applied, conflict, and stage-specific partial failure distinctly
- Read-after-write detects an unverified or concurrently changed projection
- Duplicate delivery does not duplicate an automated transition comment

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit submits its semantic outcome and schedules a short continuation retry only when
  the verified effective state remains dispatch-eligible
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- The pure state-policy matrix covers every allowed and forbidden edge, item kind, and review budget
- `Rework -> Reworking -> Review` remains distinct from implementation progress
- Same-target observations are no-ops; stale outcomes cannot regress terminal state
- Missing or multiple canonical states quarantine the item without dispatch
- Poll and webhook races are serialized through one transition request mailbox
- Duplicate and out-of-order intents are idempotent by transition and causation IDs
- A process stop after each journal phase replays to at most one projection, one automated comment,
  and one worker dispatch
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <codex.command>`
- Session startup follows the targeted Codex app-server protocol.
- Client identity/capability payloads are valid when the targeted Codex app-server protocol requires
  them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs
  using the targeted app-server protocol
- If the `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session
  - state-changing mutations are rejected from worker sessions
- Worker output schema accepts every semantic outcome and rejects target-state output or malformed
  evidence
- Worker launch strips tracker-write credentials and uses an isolated `GH_CONFIG_DIR`

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Disposable GitHub and Linear trackers exercise the full workflow lifecycle, request-label
  consumption, non-workflow label preservation, restart replay, and credential boundary.
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Pure workflow state policy and serialized state-manager request API
- Durable single-writer transition journal with restart replay
- Tracker broker for verified state projections and idempotent automated comments
- Structured worker outcomes that never select a target workflow state
- Tracker-visible `In Progress`, `Reviewing`, and `Reworking` execution states
- Human request-label validation and canonical-state drift reconciliation
- Worker/broker credential isolation
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config (`codex.command`, default `codex app-server`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes read-only Linear GraphQL queries through the
  app-server session using configured Symphony read auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- Asana, Jira, and GitLab adapters MAY poll and expose provider-native tools only in legacy mode;
  authoritative support requires broker-owned projection semantics first.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- Roll out only through `legacy -> shadow -> authoritative`; never enable dual-write.
- Before promotion, require 100% shadow-policy agreement for at least seven days and 100 transitions,
  then verify a disposable canary, hold a production allowlist for at least 72 hours and 50
  transitions, and advance through 10% -> 50% -> 100% with at least 24 hours at each stage.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
