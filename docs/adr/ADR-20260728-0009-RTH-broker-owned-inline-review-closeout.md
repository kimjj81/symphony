# ADR-20260728-0009-RTH: Broker-owned PR snapshot and inline review closeout

Tags: orchestration, pull-request, review, github, forgejo, reliability
Status: Accepted
Date: 2026-07-28
TL;DR: Symphony's broker owns both PR evidence reads and inline-thread closeout; workers receive only an immutable snapshot.

## Context

Detached workers are deliberately prohibited from changing tracker state or writing to
GitHub/Forgejo. They also run with an empty GitHub CLI configuration, so asking a preflight
agent to fetch live feedback from inside that environment produced authentication failures.
Workers could commit a correct rework, and the broker could publish it, while the pull request
still retained unresolved inline review threads. This allowed a Human Review transition to imply
a completed feedback sweep without an observable reply or resolution.

GitHub has a stable GraphQL review-thread model with reply and resolve mutations. Forgejo's
public API contract is instance/version-dependent and Symphony cannot currently prove that it
can both reply to and resolve a specific inline conversation.

## Decision

Before every briefed dispatch, the broker MUST read the live PR head, general comments, review
summaries, inline comments, and unresolved review threads using its tracker credential. The
broker renders the bounded snapshot directly; it MUST NOT launch a separate Codex preflight
session. A temporary broker read failure follows the existing bounded retry policy, while missing
authority, unsupported providers, stale heads, and exhausted retries hand off without starting a
worker.

For `rework_complete`, workers MUST return one structured update for each unresolved thread in
the supplied broker snapshot. Each update includes the opaque thread reference, a Korean reply,
focused evidence, and a disposition of `fixed` or `needs_human`. Workers remain unable to write
to the tracker or query GitHub.

After a verified broker publish, Symphony re-reads the provider's live head and review threads.
GitHub replies with a durable per-thread marker before resolving every `fixed` thread, then reads
the threads again before requesting the state transition. Unknown, newly-unaccounted, or stale
threads fail closed. `needs_human` receives its Korean reply but remains unresolved and produces a
Human Review handoff.

The publication receipt records a `review_threads_applied` phase before its existing publication
projection. A partial reply/resolve failure is retryable broker work; the marker prevents duplicate
replies while a later attempt completes the resolve.

Forgejo returns an explicit `review_thread_closeout_unsupported` handoff until the configured
instance exposes a tested public API that can both reply to and resolve the same inline thread.
Symphony does not substitute a generic pull-request comment or silently advance the rework.

## Consequences

- A Human Review transition is no longer evidence of a merely published commit; it includes a
  provider-verified inline feedback closeout for fixed threads.
- New worker output has a provider-opaque `review_thread_updates` contract, which keeps remote
  credentials, live reads, and mutations inside the broker.
- Forgejo Rework can intentionally hand off more often until its inline-thread API capability is
  implemented and covered by integration tests.

## Verification

- Worker outcome validation rejects malformed or duplicate thread updates.
- GitHub client tests cover head drift, unaccounted threads, reply/resolve order, idempotent retry,
  and `needs_human` handoff.
- Broker and journal tests cover closeout-before-transition, retry recovery, and Forgejo handoff.
