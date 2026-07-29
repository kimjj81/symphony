# ADR-20260728-0010-TCF: Workers are tracker-credential free

Tags: orchestration, tracker, security, reliability, tokens
Status: Accepted
Date: 2026-07-28
TL;DR: Symphony brokers all tracker reads and writes while workers receive only immutable evidence and no tracker credential.

## Context

Symphony already owns tracker mutations, pull-request publication, and the bounded tracker
snapshot used by briefed workers. Local workers nevertheless still received a provider read token,
while remote workers did not. This let local workers retry live tracker reads and attempted pushes
that were outside their execution contract. Authentication failures and contradictory prompt text
then turned completed repository work into repeated model dispatches.

ADR-20260720-0003-FJV allowed an explicitly configured provider read token for local workers.
ADR-20260722-0006-BRP moved pull-request publication to the broker, and
ADR-20260728-0009-RTH moved the complete pull-request evidence read to the broker. The remaining
local read-token exception no longer serves the briefed execution model.

## Decision

All Codex workers, whether local, standalone-daemon, or remote SSH, MUST start without GitHub,
Forgejo, Linear, webhook, or custom tracker credentials. They receive the broker-generated
immutable snapshot and use local Git only. Pull-request implementation and rework workers commit
in their detached worktree and return the exact HEAD OID; they MUST NOT push.

Authoritative briefed workers receive no tracker dynamic tools. During migration, legacy and
shadow workers MAY retain the broker-executed read-only `linear_graphql` dynamic tool so their
existing continuation contract does not fail closed. This compatibility path does not expose a
Linear token or direct provider transport to the worker; the broker remains the credential and
transport owner.

The broker remains the only component that reads live tracker state, publishes worker commits,
posts comments or review-thread replies, resolves threads, and projects workflow state. Tracker
transport or publication retries are broker effects and MUST NOT start another Codex worker. Once
an authoritative worker returns a valid structured outcome, any subsequent broker rejection,
conflict, publication failure, or handoff result MUST be completed or retried by the broker and
MUST NOT consume the model retry budget.

Codex app-server notifications are correlated to the root thread and turn. Explicitly mismatched
child or foreign turn notifications MUST NOT become the worker's final semantic outcome or
terminate the root turn. A normal authoritative worker exit means model work is finished; only an
explicit worker failure may consume the model retry budget.

If the root outcome is malformed, Symphony gives the same app-server session exactly one
schema-only repair turn. The repair turn runs with a read-only sandbox and network access disabled.
Because the app-server protocol does not provide a complete turn-level "no tools" switch,
Symphony MUST interrupt the repair turn on observed command, file-change, dynamic-tool, MCP,
web-search, approval, or user-input activity and discard it into a broker-owned Human Review
handoff. A second malformed outcome follows the same handoff path. Neither case may start a fresh
full worker session.

This decision supersedes the worker read-only tracker capability in
ADR-20260719-0001-QNX and the local-worker read-token allowance in
ADR-20260720-0003-FJV. State authority, provider separation, broker credential ownership, and all
other parts of those ADRs remain accepted.

## Consequences

- Local and remote workers have the same tracker authority boundary.
- Worker prompts no longer encourage a push or a repeated tracker read.
- Child-agent message interleaving cannot replace a root worker outcome when protocol identifiers
  are present.
- Broker snapshot and transition availability become required dispatch preconditions; failures
  stay in broker retry or handoff paths.
- Legacy non-authoritative execution retains its broker-executed read-only Linear continuation
  behavior during migration without receiving provider credentials.
- Repair attempts cannot mutate the repository or reach the network; an observed tool attempt
  terminates the repair and hands the result to the broker.

## Verification

- App-server tests cover token scrubbing for local, standalone, and remote workers.
- App-server tests cover the broker-only and legacy read-only dynamic-tool capability split.
- App-server tests cover child-turn message and completion interleaving before a root outcome.
- Agent-runner tests cover one same-session schema repair followed by success, malformed handoff,
  or tool-attempt interruption and broker handoff.
- Agent-runner tests prove that a rejected broker transition after a valid outcome completes
  without another model turn.
- Orchestrator tests prove that normal authoritative completion does not schedule a model retry,
  that a broker receipt suppresses a later reported runner failure, and that explicit pre-outcome
  failures still retry.
