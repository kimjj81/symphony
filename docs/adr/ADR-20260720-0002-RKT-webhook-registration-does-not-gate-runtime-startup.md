# ADR-20260720-0002-RKT: Webhook registration does not gate runtime startup

Tags: orchestration, github, webhook, startup, reliability
Status: Accepted
Date: 2026-07-20
TL;DR: Symphony starts independently of transient GitHub webhook registration failures and retries registration for the lifetime of the runtime process.

## Context

The Myven launcher registered its GitHub webhook synchronously before starting Symphony in fixed
webhook mode. A transient GitHub API failure therefore terminated the launcher even though the local
runtime, repository, transition journal, and observability API were healthy. Git operations and
GitHub webhook delivery can also have different availability from GitHub API requests, so treating
registration as a startup prerequisite coupled unrelated failure domains.

Ignoring registration failures entirely would keep the runtime alive but leave it unable to recover
webhook delivery automatically. Starting an unbounded retry without tying it to the runtime process
would leak background processes after Symphony exits.

## Decision

Webhook registration is an asynchronous control-plane operation. In fixed and relay modes, the
launcher MUST start registration in the background and start Symphony without waiting for a
successful GitHub API response. Failed registration attempts MUST be logged and retried at a
configurable interval for as long as the Symphony process remains alive.

The launcher MUST also surface degraded registration state on its terminal. HTTP 5xx responses are
identified as GitHub API server failures, while other failures use a generic registration warning
that does not misclassify authentication or permission errors as a provider outage. Recovery MUST be
reported without requiring an operator to inspect the registration log.

The registration worker is owned by the launcher. When Symphony exits or the launcher receives a
termination signal, the launcher MUST terminate and reap the registration worker. Ngrok mode uses
the same managed registration lifecycle after its local API becomes ready.

Local executable prerequisites remain startup validation errors. Tracker reads and state
transitions remain fail-closed: keeping the runtime process alive does not authorize dispatch from
stale or unavailable GitHub state.

## Consequences

- A transient GitHub API outage no longer prevents Symphony observability, journal recovery, or
  eventual webhook registration.
- Registration automatically converges when GitHub recovers without a manual runtime restart.
- Operators see degradation and recovery on the launcher terminal, while the webhook registration
  log retains the underlying GitHub CLI error.
- A permanently invalid credential or repository permission causes continued retries and log noise;
  alerting on prolonged registration failure remains an operational follow-up.
- The launcher must continue to manage child-process cleanup and signal propagation explicitly.

## Acceptance

- A simulated HTTP 503 during both webhook update and creation does not prevent Symphony startup.
- The launcher terminal reports the HTTP 503 degradation and that Symphony remains running.
- Registration is retried and succeeds automatically when the simulated API recovers.
- The launcher terminal reports registration recovery after a failed attempt.
- Exiting Symphony terminates the registration retry worker without waiting for the next retry delay.
