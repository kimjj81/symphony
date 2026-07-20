# ADR-20260720-0003-FJV: Forgejo is a first-class tracker provider

Tags: orchestration, tracker, forgejo, github, webhook, security
Status: Accepted
Date: 2026-07-20
TL;DR: Symphony uses a separate Forgejo v16 adapter while sharing workflow-state policy and broker safety with the GitHub adapter.

## Context

Symphony's tracker boundary is provider-neutral, but the existing hosted-Git implementation embeds
GitHub REST paths, payloads, identifiers, webhook signatures, native sub-issues, and credential
names. Pointing that client at a Forgejo endpoint would silently mix incompatible label, branch,
merge, hierarchy, and webhook contracts.

The state manager and broker must remain the only automated tracker writers. A provider switch must
also not replay journaled effects against a different service or expose a Forgejo write token to a
Codex worker.

## Decision

`forgejo` is a distinct `tracker.kind` implemented by its own adapter and REST client. It uses
provider-qualified `forgejo:issue:*` and `forgejo:pr:*` identifiers while reusing the existing
tracker behaviour, workflow-state labels, transition journal, and semantic worker outcomes.

The supported API contract is Forgejo major version 16 at an endpoint ending in `/api/v1`.
Preflight checks fail closed on another major version without terminating Symphony's observability
process. Forgejo webhook deliveries use their native headers and HMAC signature on a separate HTTP
route, and their transition IDs are namespaced by provider.

Forgejo hierarchy is represented by exactly one `sym:parent-<number>` label on each child issue.
The label is preserved as relationship metadata during state projection. Missing relationship
labels mean an ordinary issue; malformed or multiple parent labels are conflicts.

Parent lifecycle is guarded by the StateManager: the Forgejo client returns a typed deferral when
an active declared child prevents a terminal parent projection. The Orchestrator records a separate
Human Review handoff, and after a child becomes terminal it records a separate
`children_completed` parent transition. A parent with declared children but no open Planned child
never receives a direct implementation PR. The client never silently substitutes a target state or
writes a parent completion outside the transition journal.

Forgejo physical lifecycle is kept separate from the canonical workflow label. A merged pull with
an outstanding `sym:merging` label remains `Merging` for exactly one StateManager pass, which
journals and projects `sym:done`; it then normalizes as `Done`. A reopened terminal item becomes a
StateManager `reopen` request and is projected to `Human Review`, including the underlying Forgejo
open state. This prevents physical merge/reopen events from silently bypassing canonical-label
projection.

Local workers may receive an explicitly configured tracker read token, but remote SSH workers
receive no tracker token. Supplying it as a remote command environment assignment would expose it
through the local SSH process arguments, while workers do not require tracker credentials for the
Forgejo branch-to-PR workflow.

The broker uses Forgejo's label IDs, branch and pull-request APIs, and a squash merge request pinned
with `head_commit_id`. It verifies the pull request before and after merge. Worker processes remove
Forgejo write credentials and may receive only the separately configured read token. When a write
credential is configured through `$ENV_NAME`, the broker retains only that variable name as internal
provenance and removes it from local and remote worker environments. Standalone daemons launch Codex
with an explicit environment allowlist, so unclassified custom write-token variables cannot be
inherited.

Signed Forgejo webhooks require exactly one non-empty bounded event, delivery, and raw lowercase
hex signature header. They are accepted only for the active Forgejo tracker when both the payload
repository identity and URI origin match the configured `owner/repo` and endpoint instance. The
processor accepts Forgejo v16 native event/action names and the established compatibility aliases,
normalizing label additions/removals from either top-level or `changes` payload fields. Delivery IDs
are journaled before refresh scheduling: a replay with the same payload is a no-op and a reused
delivery ID with a different payload is rejected. Head/review events are no-effect journaled intents
that still trigger one targeted refresh; inactive-provider and cross-instance deliveries are ignored
before either intent ingestion or refresh.

Forgejo major readiness is a broker boundary: every Forgejo write and new dispatch path checks
preflight, while polling reads, dashboard availability, and journal recovery remain available on an
unsupported major. Worker environments remove GitHub and Forgejo webhook secrets in addition to all
tracker write-token variables. Local workers may receive only an explicitly injected provider read
alias; remote workers receive no tracker token. Standalone workers require configured write-token
variable provenance and fail closed when it is unavailable, rather than inheriting an unclassified
environment variable.

## Consequences

- GitHub and Forgejo lifecycle behavior remains aligned at the tracker boundary without pretending
  their wire APIs are interchangeable.
- Existing GitHub and Linear identifiers and journal entries remain unchanged. Pending entries with
  another provider prefix are quarantined instead of replayed.
- Forgejo major upgrades require an explicit compatibility review and test update.
- Parent labels are deterministically queried with Forgejo's label filter, but repository operators must maintain them;
  malformed labels and incomplete children fail closed.
- Split PR headings must form an unambiguous `PR1` through `PRN` sequence. Feature and integration
  PR titles use the same `[current/total]` convention.
- Fork and cross-instance pull requests, Forgejo NATS relays, and new CI/review approval policy are
  outside this decision.

## Verification

- Unit and integration tests cover physical-state repair, parent guards and synchronization,
  idempotent PR convergence, repository-bound webhook validation, journal fencing, and credential
  isolation including custom write-token environment variables.
- An opt-in Docker smoke runs the lifecycle against a pinned Forgejo v16 image.
