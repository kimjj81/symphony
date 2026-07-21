# ADR-20260721-0004-WEP: Preflight does not authorize worker execution

Tags: orchestration, state-machine, codex, reliability
Status: Accepted
Date: 2026-07-21
TL;DR: Symphony derives each worker's execution mode and permitted outcome from tracker state; the read-only preflight supplies evidence only.

## Context

Symphony runs orchestration preflight in a read-only Codex session before starting a worker. The
same free-form preflight output was embedded in the worker prompt with fields for lane, allowed
scope, and transition guidance. A preflight for Myven PR #550 interpreted its own read-only sandbox
as the downstream worker's scope, so a writable implementation worker returned `handoff_required`
without changing the approved pull request.

The tracker state already identifies the intended lifecycle lane, and the StateManager is the only
authority that can apply tracker transitions. Letting a model-generated evidence summary redefine
either responsibility makes a transient prompt interpretation a control-plane decision.

## Decision

Symphony derives an immutable worker execution contract from the restored dispatch state. Todo is
the planning lane. Planned and In Progress are implementation lanes regardless of item kind;
review, rework, and merge states retain their respective lanes. Unsupported states do not start a
preflight or worker: they receive a deterministic Human Review handoff.

The preflight schema is limited to live head, unresolved feedback, focused verification, and
factual stop conditions. It cannot emit execution lane, write scope, transition instructions, or
permitted semantic outcomes. The worker prompt labels the preflight as evidence only and explicitly
states that its read-only sandbox cannot narrow the derived execution contract.

The worker output schema is generated from that contract. An implementation worker can return
`implementation_complete`, `blocked`, or `handoff_required`, but cannot return a review outcome;
equivalent lane-specific restrictions apply to planning, review, rework, and merge workers.

## Consequences

- An empty bootstrap PR is an implementation starting point rather than a reason for a preflight to
  redirect the worker to human review.
- A malformed or overly broad preflight summary cannot turn a writable implementation lane into a
  read-only one.
- Preflight remains useful for current head and feedback evidence without becoming a second state
  authority.
- New lifecycle lanes require an explicit execution-contract mapping and semantic-outcome policy.

## Verification

- Regression coverage reproduces a Planned pull request projected to In Progress and a general
  issue already In Progress, each with a contradictory read-only preflight snapshot, and verifies
  `implementation_complete` is accepted.
- Unsupported states are covered in authoritative and legacy modes to verify that neither
  preflight nor worker sessions start before the Human Review handoff.
- Existing review, rework, merge, and preflight decoding tests retain their lane-specific behavior.
- The Elixir quality gate validates formatting, tests, coverage, Credo, and Dialyzer.
