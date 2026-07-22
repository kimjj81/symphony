# ADR-20260722-0006-BRP: Broker publishes verified pull-request commits

Tags: orchestration, git, pull-request, reliability
Status: Accepted
Date: 2026-07-22
TL;DR: Detached Codex workers commit locally while Symphony's broker verifies, integrates, and non-force publishes the resulting PR head before any state transition.

## Context

Symphony creates pull-request worker worktrees at a detached remote head so concurrent
workers never contend for one local branch checkout.  A worker can therefore create a valid
commit without changing the pull-request branch.  Treating that local commit SHA as the
remote PR head caused the authoritative stale-head guard to correctly reject the completion,
but left useful work unpublished.

The broker and local worker run on the same host and account.  The authority boundary here is
therefore workflow ownership and replayable evidence, rather than an operating-system security
boundary.  Workers still must not choose tracker state or publish PR branches directly.

## Decision

For pull-request `implementation_complete` and `rework_complete` outcomes, the worker MUST
commit in its detached worktree and return that exact SHA.  The broker MUST record the dispatch
base SHA, worker SHA, final structured evidence, changed files, and deterministic patch digest
before using a normal non-force push.

If the branch did not move, the broker pushes the worker SHA.  If the remote already contains
the worker SHA, it records an idempotent publish.  If both the branch and worker advanced from
the dispatch base, the broker creates a short-lived detached worktree and rebases the worker
commits onto the live branch head.  A clean rebase is pushed and its new SHA becomes the worker
outcome's head for the authoritative state transition.

A rebase conflict, rewritten remote history, missing commit, or unverifiable ancestry requires
`handoff_required`; the broker publishes the Korean handoff with the recorded provenance.  A
transport failure remains a broker publication effect and MUST NOT make Codex repeat repository
work.  The state manager retains its stale-head protection and receives only the rechecked
published SHA.

Publication has its own durable receipt. Git publication reaches `projection_applied`, but it
MUST NOT become `verified` until the exact corresponding semantic state-transition receipt is
durably terminal. Each publication receipt carries the final base, worker, live, and published
SHAs, integration result, and `state_transition_id`; this receipt is the single source of truth
for replay and tracker provenance. A handoff receipt records its Korean reason, sanitized
provenance, and broker handoff transition ID at `projection_applied`, then remains non-terminal
until that Human Review transition is terminal.

After a crash, the broker restores pending publication issue claims before orphan-dispatch
recovery. It checks the stored `state_transition_id`, rather than searching by session or kind;
only a verified applied result completes publication. `noop`, rejected, and conflicting state
results do not. A tracker head that moves between push and the state request is re-fetched through
the same graph check; the receipt is durably updated with the newly confirmed provenance and state
transition ID before the request is retried. Transient Git and tracker effects remain retryable
broker work and MUST NOT start another Codex turn.

`stale_causation` means a newer dispatch has superseded the worker outcome. The broker records the
publication receipt as verified `obsolete`, releases its recovered claim, and schedules a targeted
refresh without re-publishing, re-running Codex, or creating a human handoff. Only an
irreconcilable graph or rebase conflict becomes a human handoff.

The broker fails closed for an authoritative PR code outcome without a dispatch base, branch,
worker SHA, or journal.  The resulting handoff is broker-sourced, so an unavailable confirmed
remote head never masquerades as the detached worker SHA.  Tracker comments receive a sanitized
provenance projection (SHAs, branch, integration, changed files, and patch digest); workspace
paths and raw Git transport output remain journal-only evidence.

Workers never receive a direct-push instruction for either implementation or rework.  Remote
worker publication is intentionally unsupported by this decision; it must hand off rather than
silently run a remote publish command.

## Consequences

- Detached worktrees remain safe for concurrent implementation while one broker owns branch
  publication and tracker state effects.
- Every automatic publish has durable Git and structured-worker provenance.
- A concurrent branch update is automatically integrated only when Git can do so deterministically;
  semantic conflicts remain visible to a human.
- Pending publication claims fence orphan worker-dispatch recovery until publication completes or
  becomes obsolete. A normal worker continuation uses a monotonically new dispatch attempt.

## Verification

- Workspace tests cover direct, idempotent, rebased, conflicting, and invalid-ancestry publishes.
- Agent-runner integration covers a detached worker commit plus a concurrent conflicting remote
  append, asserting that the publication receipt remains `projection_applied` while the broker
  applies the handoff and becomes verified only afterward.
- Journal-backed state-manager integration covers startup claim restoration for a pending transport
  publication, handoff replay, obsolete stale causation release and refresh, and exact
  `state_transition_id` checks that preserve final published provenance.
- Orchestrator tests cover monotonic continuation attempts and recovery of an already-reserved
  worker lease without leaving an isolated claim.
