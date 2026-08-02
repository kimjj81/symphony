# ADR-20260802-0012-LGP: Generic tracker providers remain legacy-only

Tags: tracker, orchestration, security, asana, jira, gitlab
Status: Accepted
Date: 2026-08-02
TL;DR: Add upstream Asana, Jira, and GitLab polling and tools without weakening the fork's authoritative broker boundary.

## Context

Upstream Symphony added Asana, Jira, and GitLab adapters that poll provider-native issues and expose
provider REST tools to Codex sessions. This fork separately established that authoritative workers
are tracker-credential free and return semantic outcomes while Symphony owns journaled tracker
writes. The new adapters do not implement the fork's dispatch snapshot, compare-and-set projection,
publication, review closeout, or durable effect contracts.

Treating those adapters as authoritative would advertise a safety property they do not provide.
Dropping them entirely would also discard useful upstream compatibility for workflows that still
use the legacy execution model.

## Decision

Symphony supports `asana`, `jira`, and `gitlab` tracker kinds only when
`state_manager.mode == "legacy"`. Configuration validation MUST reject those providers in `shadow`
or `authoritative` mode.

The host loads provider credentials and binds the selected provider settings and tool contract once
when an app-server session starts. The worker process environment MUST have the canonical provider
credential variables and any configured credential-source variables removed. Provider requests are
executed by the Symphony host through `asana_api`, `jira_rest`, or `gitlab_api`; the raw token is not
passed to Codex.

These legacy provider tools MAY perform mutations allowed by their configured token. Their authority
is therefore the token's provider-side scope, not the fork's state-manager policy. Operators MUST use
least-privilege credentials and SHOULD isolate them to the intended project.

Polling normalizes provider items into the shared tracker issue shape. `tracker.required_labels`
MAY further restrict dispatch, and all configured labels MUST match case-insensitively. The generic
adapters use their configured `active_states` and `terminal_states`.

GitHub, Forgejo, and Linear retain their existing fork-specific behavior. Authoritative support for
Asana, Jira, or GitLab requires a later ADR and implementations of broker-owned immutable dispatch
evidence, idempotent state projection, verification, durable effects, and provider-scoped write
authorization.

This decision narrows only the legacy compatibility exception in ADR-20260728-0010-TCF; it does not
change the authoritative worker credential boundary.

## Consequences

- Existing authoritative GitHub, Forgejo, and Linear workflows keep their broker-owned state model.
- Legacy users can adopt upstream Asana, Jira, and GitLab polling and provider tools.
- A generic provider cannot be enabled accidentally in shadow or authoritative mode.
- Host-side tools keep tokens out of the child process but still carry the full provider-side token
  authority; this is a documented legacy risk.
- Provider settings are session-bound, so a live workflow reload affects new sessions rather than
  changing credentials midway through an existing turn.

## Verification

- Configuration tests accept each generic provider in legacy mode and reject it in shadow and
  authoritative modes.
- Adapter tests cover provider validation, pagination, issue normalization, label routing, bound
  tool settings, and secret-environment discovery.
- App-server tests cover provider tool advertisement, execution, session binding, and credential
  scrubbing for local and remote workers.
- The full Elixir verification suite remains the merge gate.
