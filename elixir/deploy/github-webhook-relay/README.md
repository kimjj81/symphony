# GitHub Webhook Relay for Symphony

This directory contains a small, secret-free deployment kit for relaying GitHub webhook deliveries from a public Oracle k3s endpoint to local consumers.

The relay is intentionally transport-only:

- accepts GitHub webhook POSTs;
- verifies `X-Hub-Signature-256` when `GITHUB_WEBHOOK_SECRET` is configured;
- wraps the raw payload in a compact envelope;
- publishes every delivery to NATS JetStream;
- does not inspect labels;
- does not perform workflow actions;
- does not run Codex or mutate GitHub.

The Symphony consumer owns workflow semantics and filters `sym:*` labels.

## Architecture

```text
GitHub Webhook
  -> Cloudflare Tunnel / public domain
  -> Oracle k3s Service: github-webhook-relay
  -> NATS JetStream stream: GITHUB_WEBHOOKS
  -> Symphony NATS webhook consumer
```

The Mac does not need inbound network access. It opens an outbound NATS connection and receives events through a durable JetStream consumer.

## Contents

```text
relay/                         Python aiohttp + nats-py webhook receiver
local/                         shared local NATS tunnel launchd template
k8s/                           namespace, NATS values, relay deployment/service/ingress examples
scripts/                       local verification helpers
```

## Pilot order

1. Build/push the relay image to a registry you control.
2. Install NATS JetStream in `oracle-cluster` using `k8s/nats-values.yaml`.
3. Apply `k8s/namespace.yaml` and create secrets from `k8s/secrets.example.yaml` manually.
4. Deploy the relay and expose it through Cloudflare Tunnel / your k3s ingress.
5. Configure GitHub webhook URL to `https://<domain>/github`.
6. Install the shared local NATS tunnel when Symphony runs outside the cluster.
7. Enable Symphony's NATS webhook consumer with its own durable consumer name.
8. Verify a `sym:*` webhook delivery is processed by Symphony.

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
