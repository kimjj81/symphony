# ADR-20260729-0011-YIX: Bounded indexed orchestration evidence sidecars

Tags: orchestration, evidence, pull-request, worker, ssh, reliability
Status: Accepted
Date: 2026-07-29
TL;DR: Briefed workers receive a compact 8 KiB manifest plus a broker-owned indexed YAML evidence sidecar capped at 8 MiB.

## Context

ADR-20260728-0009-RTH made the broker responsible for collecting complete pull-request evidence,
and ADR-20260728-0010-TCF removed tracker credentials from workers. The first implementation
serialized the work-item description, every general comment, review summary, inline comment, and
unresolved thread into one 8 KiB prompt fragment.

Long pull-request bodies and broker-generated completion comments could exceed that limit before a
worker started. Raising the prompt limit would only postpone the same cumulative failure. Lossy
summarization or arbitrary truncation would risk removing exact human feedback, unresolved thread
references, or verification exclusions needed by Review, Rework, and Merging workers.

## Decision

Every briefed dispatch MUST render a compact manifest no larger than 8 KiB and a separate immutable
YAML evidence sidecar no larger than 8 MiB. The manifest contains the work-item identity, live head,
sidecar byte size and SHA-256, required evidence regions, and inclusive line indexes. It does not
repeat full tracker bodies.

The sidecar MUST use a deterministic schema and fixed region order: work item, unresolved threads,
human comments, review summaries, inline comments, worker reports, transition history, and a
deduplication report. It MUST preserve unresolved thread text and opaque thread references without
deduplication, including paginating every nested review-thread comment connection. Other evidence
may collapse only exact duplicates with the same author, state, path, and line; marker removal MUST
NOT trim or otherwise normalize the remaining body. All original occurrence identifiers,
timestamps, URLs, and Symphony transition markers remain recorded. Literal bodies use YAML's
explicit indentation indicators with deterministic chomping: `|-2` when the normalized body has no
trailing LF and `|+2` when it has one or more trailing LFs. This preserves leading whitespace and
the exact normalized trailing-LF count through round-trip parsing without changing schema version 1.

Top-level review-thread and nested comment pagination MUST accept only `hasNextPage: false` as a
terminal page. Missing, empty, or repeated cursors and malformed page information fail the entire
snapshot instead of dispatching partial evidence.

The broker MUST parse the generated YAML, compare every parsed index field with the computed index,
and verify every indexed region's inclusive line range, item count, byte size, and digest before
dispatch. An oversized, incomplete, or invalid sidecar fails closed without starting a worker.

The app-server runtime writes the sidecar with read-only permissions beneath its session-specific
temporary directory and exposes its path through `SYMPHONY_ORCHESTRATION_EVIDENCE`. Local writes
and SSH uploads MUST be verified against the broker digest before Codex starts. SSH workers receive
the file through OpenSSH `scp`; partial upload, missing transport, or digest mismatch is a startup
failure. Existing runtime cleanup removes the file when the session stops or startup fails.

Workers MUST read the index and every lane-required region before acting. They MAY read optional
regions when the required evidence is insufficient. Workers remain tracker-credential free and
MUST NOT mutate the sidecar or query the tracker.

Every fresh app-server worker turn MUST fetch a new broker snapshot and create a new manifest and
sidecar. Continuation turns MUST NOT reuse evidence from the previous lane or worker session.

## Consequences

- Large but bounded tracker histories no longer consume the compact prompt budget.
- Human feedback and unresolved review context remain available without lossy model summarization.
- Workers can read only relevant line ranges instead of loading the entire history into context.
- Continuation turns incur a fresh tracker read so lane changes cannot reuse stale evidence.
- SSH worker hosts require a compatible OpenSSH `scp` client on the Symphony host and standard
  SHA-256 tools on the worker host.
- Evidence larger than 8 MiB intentionally hands off rather than silently dropping context.

## Verification

- Sidecar tests cover whitespace-preserving YAML round trips including trailing LFs, parsed line
  indexes, section digests, exact deduplication, fail-closed review-thread pagination, and the
  inclusive serialized 8 MiB boundary.
- Agent-runner tests cover compact-manifest sizing, fresh evidence per worker turn, lane-required
  regions, Human Review handoff, and a long PR history that previously exceeded 8 KiB.
- App-server and SSH tests cover local permissions, environment exposure, upload arguments, digest
  verification, and runtime cleanup.
