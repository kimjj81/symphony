# ADR-20260721-0005-QXB: Acknowledge state-less webhook drift

Tags: orchestration, github, forgejo, webhook, nats, reliability
Status: Accepted
Date: 2026-07-21
TL;DR: Symphony journals state-label drift without committed state as a no-effect receipt so permanent semantic conditions are acknowledged without suppressing retries for transient failures.

## Context

GitHub and Forgejo state-label events are delivered through a shared webhook processor. A direct
canonical-label change is normalized as projection drift and sent to the authoritative state
manager. Reconciliation requires a previously verified canonical state in the transition journal.

A delivery can legitimately arrive without that history. The item may predate authoritative mode,
the label event may be an intermediate tracker snapshot, or the item may never have received a
Symphony transition. Retrying the same immutable delivery cannot create the missing history.

The NATS consumer negatively acknowledges every ingestion error. A delivery with a running journal
but no committed state was therefore redelivered indefinitely. With a pull batch size of one,
repeated delivery consumed most polling capacity and delayed unrelated webhooks by several minutes.

## Decision

For a GitHub or Forgejo projection-drift delivery with no committed canonical state, Symphony MUST
record the delivery as a verified, refresh-only, no-effect journal receipt. The delivery is then
acknowledged and the normal targeted refresh still runs. Symphony MUST NOT invent a canonical
state, change labels, or publish a reconciliation comment in this case.

This exception applies only to provider-qualified tracker webhook projection drift. Internal
callers without a webhook source still receive `canonical_state_unavailable`, and operator request
labels continue through the authoritative request validation and quarantine policy.

Journal, orchestrator, tracker, and transport unavailability remain retryable errors. Malformed
envelopes remain terminal immediately. This decision does not impose a global JetStream delivery
limit: doing so without dead-letter observability could silently strand transient failures, and
updating an existing durable consumer's retry fields requires separate live-server compatibility
proof.

The transition journal is the state-intent idempotency boundary. Replaying the same state-less drift
delivery does not repeat a state effect, but targeted refresh remains retryable until the enclosing
webhook delivery succeeds. Reusing a delivery ID with different content remains an error. A receipt
interrupted after `received` or `decided` resumes from that phase and reaches `verified` before the
delivery is acknowledged.

## Consequences

- The known permanent semantic condition cannot create an infinite hot-redelivery loop or starve
  unrelated webhook traffic.
- State-less drift is observable in the transition journal without granting it authority to choose
  or restore a workflow state.
- Partial no-effect receipts are crash-resumable and cannot become poison deliveries themselves.
- A canonical state that becomes available after the delivery is acknowledged is discovered by the
  targeted refresh and regular polling rather than by replaying the old drift event.
- Transient infrastructure failures retain unlimited broker-managed retry behavior.
- Bounded delivery and dead-letter handling remain a separate operational reliability decision.

## Verification

- Integration tests prove state-less webhook drift is journaled once and performs no tracker write.
- Existing webhook, state-manager, and full Elixir verification suites remain green.
