# GitHub Webhook Relay for Symphony + Hermes Kanban

This directory contains a small, secret-free deployment kit for relaying GitHub webhook deliveries from a public Oracle k3s endpoint to local consumers.

The relay is intentionally transport-only:

- accepts GitHub webhook POSTs;
- verifies `X-Hub-Signature-256` when `GITHUB_WEBHOOK_SECRET` is configured;
- wraps the raw payload in a compact envelope;
- publishes every delivery to NATS JetStream;
- does not inspect labels;
- does not decide Symphony vs Hermes;
- does not run Codex or mutate GitHub.

Downstream consumers own workflow semantics:

- Symphony consumer filters `sym:*` labels.
- Hermes consumer filters `hermes:*` labels and reconciles the `myven` Kanban board.

## Architecture

```text
GitHub Webhook
  -> Cloudflare Tunnel / public domain
  -> Oracle k3s Service: github-webhook-relay
  -> NATS JetStream stream: GITHUB_WEBHOOKS
  -> local Mac consumer: myven-hermes-consumer
       -> hermes kanban --board myven ...
  -> optional Symphony consumer
```

The Mac does not need inbound network access. It opens an outbound NATS connection and receives events through a durable JetStream consumer.

## Contents

```text
relay/                         Python aiohttp + nats-py webhook receiver
consumer/                      Mac-side Hermes Kanban consumer + launchd template
k8s/                           namespace, NATS values, relay deployment/service/ingress examples
scripts/                       local verification helpers
```

## Pilot order

1. Build/push the relay image to a registry you control.
2. Install NATS JetStream in `oracle-cluster` using `k8s/nats-values.yaml`.
3. Apply `k8s/namespace.yaml` and create secrets from `k8s/secrets.example.yaml` manually.
4. Deploy the relay and expose it through Cloudflare Tunnel / your k3s ingress.
5. Configure GitHub webhook URL to `https://<domain>/github`.
6. Install the Mac consumer with launchd.
7. Add a `hermes:*` label to a low-risk Myven test issue and verify the consumer logs a dry-run action.
8. Disable dry-run only after the task creation/update behavior is correct.

## No secrets in git

Files in this directory intentionally contain placeholders only. Do not commit real values for:

- `GITHUB_WEBHOOK_SECRET`
- `NATS_AUTH_TOKEN`
- `NATS_URL` if it embeds credentials
- GitHub tokens
- Cloudflare tunnel credentials

Use Kubernetes Secrets, local `.env` files, launchd environment variables, or your password manager.

## Oracle access note

The manifests are safe to generate without Oracle access. Actual install/verification requires a working `kubectl --context oracle-cluster` and the registry/domain details for your environment.
