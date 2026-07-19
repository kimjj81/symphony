# ADR-20260719-0001-QNX: Symphony owns tracker workflow state

Tags: orchestration, state-machine, tracker, github, linear, reliability
Status: Accepted
Date: 2026-07-19
TL;DR: Symphony serializes every automated workflow transition and projects one canonical state to the tracker; workers return semantic outcomes and never mutate workflow state directly.

## Context

Symphony previously treated tracker labels as both durable workflow state and a worker coordination
protocol. The orchestrator, agent runner, webhook handlers, tracker adapters, and coding agents could
all change that state. A worker therefore had to infer success by reading labels after its turn, and
a late result could overwrite a newer or terminal state. Same-state observations such as
`Review -> Review` and `Merging -> Merging` were also indistinguishable from failed work.

Keeping `In Progress` and `Reviewing` visible in GitHub is operationally useful, so execution phases
remain tracker-visible. Rework execution receives its own `Reworking` state rather than collapsing
its origin into the generic `In Progress` state.

## Decision

### One transition authority

The orchestrator mailbox is the only entry point for automated transition intents. A pure workflow
policy converts an observed state and a semantic intent into a transition plan. A state manager then
serializes the plan, durable effects, and verification. Tracker adapters apply projections; they do
not decide business transitions.

The transition request contract includes a stable transition ID, tracker item ID, source and actor,
expected state, semantic intent, causation ID, and observed head OID when relevant. Results distinguish
applied, already-applied, conflict, policy rejection, and transport failure. Terminal states are
monotonic: a stale worker outcome is a successful no-op and MUST NOT regress `Done`, `Canceled`, or
`Duplicate`.

### Semantic worker outcomes

Workers return one of the following outcomes instead of a target state:

- `planning_complete`
- `implementation_complete`
- `rework_complete`
- `clean_review`
- `review_findings`
- `merge_ready`
- `blocked`
- `handoff_required`

The result also carries the observed head OID, verification evidence, and a Korean summary suitable
for a tracker update. Workers MUST NOT add or remove `sym:*` workflow labels, publish automated
transition comments, close or reopen tracker items, or merge pull requests directly. Symphony's
tracker broker owns those effects and adds `<!-- sym-transition:<transition-id> -->` to generated
comments for idempotency. Human-authored comments remain unrestricted.

### Tracker projection and operator requests

Each tracked item has exactly one canonical workflow-state label. The active execution transitions
are:

- `Planned -> In Progress -> Review`
- `Review -> Reviewing -> Human Review | Rework`
- `Rework -> Reworking -> Review`
- `Merging -> Done` only after a successful merge is observed

People request state changes with temporary labels rather than editing canonical labels:

- `sym:request-planned`
- `sym:request-rework`
- `sym:request-merging`
- `sym:request-human-review`
- `sym:request-canceled`
- `sym:request-duplicate`
- `sym:request-reopen`

A webhook delivers the request as an immutable intent. Symphony re-reads live state, validates the
edge, consumes the request label, and restores exactly one canonical state label. Multiple request
labels, missing or multiple canonical states, unauthorized edges, and direct canonical-label edits
are quarantined or reconciled to the last verified state instead of dispatching work. A self-authored
projection webhook is an acknowledgement, not a new intent.

Adapters preserve non-workflow labels. GitHub projection replaces the complete label set in one
request after a fresh read and performs a read-after-write verification. Equivalent expected-state
and verification semantics apply to Linear.

### Durable transition journal

Symphony records transition progress in an OTP `:disk_log` write-ahead journal with these phases:

`received -> decided -> required_comment_applied -> projection_applied -> verified`

`retrying` records a recoverable external-effect failure without changing the displayed execution
state. The log is synchronized before every external effect. On restart, Symphony replays incomplete
transitions and uses the transition ID, comment marker, expected state, and tracker readback to avoid
duplicate comments or projections. Only one process may hold the workflow journal; a second writer
fails closed.

The default journal location is
`${XDG_STATE_HOME:-~/.local/state}/symphony/<workflow-path-hash>/transitions.log`.

### Credential boundary

Only the broker receives tracker-write credentials. Worker environments remove `GITHUB_TOKEN`,
`GH_TOKEN`, and `SYMPHONY_TRACKER_WRITE_TOKEN`, use an empty `GH_CONFIG_DIR`, and receive a
read-only tracker capability. Git pushes use a separate repository credential. Operations that
require tracker write authority, including automated comments and merges, go through a run-scoped
broker API whose caller cannot choose a target state.

### Migration modes

Rollout supports `legacy`, `shadow`, and `authoritative` modes, never dual-write:

- `legacy` keeps the previous writer while the new manager is disabled.
- `shadow` computes and records the new policy decision while the single legacy writer applies the
  transition once; the new broker performs no projection, comment, merge, or other tracker write.
- `authoritative` enables the broker and disables every legacy automated writer.

Rollback disables authoritative writes while preserving the journal. A legacy writer cannot be
re-enabled until the authoritative writer has released its lock and fencing has been verified.

Promotion requires at least seven days and 100 transitions with 100% shadow-policy agreement, then
a disposable canary, a production allowlist held for 72 hours and 50 transitions, and staged
10% -> 50% -> 100% rollout with at least 24 hours at each stage.

## Consequences

- State decisions become deterministic and unit-testable independently of tracker transport.
- GitHub and Linear share one workflow policy and differ only in projection mechanics.
- Visible `In Progress`, `Reviewing`, and `Reworking` labels keep operational state legible.
- Automated tracker effects require durable replay, conflict handling, and stronger observability.
- Tracker-write credentials move out of coding-agent sessions; direct worker use of general-purpose
  write tools is no longer a supported workflow contract.
- External APIs are not one transaction. Effectively-once behavior depends on journal replay,
  idempotency markers, expected-state checks, and read-after-write verification.

## Migration and acceptance

Before authoritative cutover, all legacy write sites must route through the state manager or broker,
worker prompts must return structured outcomes, and webhook handlers must be ingestion-only. Shadow
mode must show 100% policy agreement for at least seven days and 100 transitions. A disposable
tracker canary then verifies the complete lifecycle, restart replay, non-workflow label preservation,
request-label handling, and credential isolation before a staged production rollout.

Any terminal regression, ambiguous canonical state, duplicate transition comment or worker dispatch,
write outside the broker, or unrecovered journal mismatch blocks promotion.
