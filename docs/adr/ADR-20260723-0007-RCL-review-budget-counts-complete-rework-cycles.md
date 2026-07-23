# ADR-20260723-0007-RCL: Review budget counts complete automatic rework cycles

Tags: orchestration, review, rework, workflow, reliability
Status: Accepted
Date: 2026-07-23
TL;DR: A review budget of three permits three review-and-rework cycles followed by one confirmation review, not only three review verdicts.

## Context

`agent.max_review_verdicts` was documented and implemented as a raw count of review verdicts.
With its value set to three, the third `review_findings` result was sent directly to `Human Review`.
Only two rework turns could therefore run. The Myven workflow also allowed seven turns, which is
one fewer than the eight turns needed for an implementation turn, three review/rework cycles, and
a final confirmation review.

This made the visible workflow shorter than the intended operator contract: complete up to three
automatic implementation/review/rework sets, then involve a person only if a further review still
finds work to do.

## Decision

For compatibility, the configuration key remains `agent.max_review_verdicts`, but its value is the
maximum number of automatic `review_findings -> Rework` cycles. A finding on review attempts one
through the configured limit enters `Rework`. After the final rework completes, Symphony runs one
confirmation review:

- `clean_review` enters `Human Review` as usual.
- `review_findings` enters `Human Review` without another automatic rework.

With the default value of three, the maximum automatic path from implementation is:

`implementation -> review 1 -> rework 1 -> review 2 -> rework 2 -> review 3 -> rework 3 -> confirmation review`

The Myven workflow retains `agent.max_turns: 8` so the complete path is reachable in a legacy
briefed worker run. In authoritative mode, each state transition dispatches one worker turn and
the transition journal preserves the review counter across those dispatches. Workflows that use
legacy briefed runs with a different budget must leave enough turns for the initial implementation,
each permitted review/rework cycle, and the confirmation review.

## Consequences

- A configured limit of three now executes three actual rework sets rather than two.
- Review findings are still bounded: a fourth finding at the default limit is handed to a person.
- The established configuration key is retained, so existing workflow files remain valid, but its
  effective semantics are documented as an automatic rework-cycle budget.
- Tests cover the third permitted rework, the fourth confirmation-review handoff, replay behavior,
  and the workflow turn allowance.
