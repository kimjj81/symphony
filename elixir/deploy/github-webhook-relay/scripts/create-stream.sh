#!/usr/bin/env bash
set -euo pipefail

# Create/update the JetStream stream used by the GitHub webhook relay.
# Run from a shell with nats CLI access to the target server, for example:
#   NATS_URL=nats://... NATS_AUTH_TOKEN=... ./create-stream.sh

STREAM=${NATS_STREAM:-GITHUB_WEBHOOKS}
SUBJECTS=${NATS_SUBJECTS:-github.webhook.*}
MAX_AGE=${NATS_MAX_AGE:-14d}
DUP_WINDOW=${NATS_DUPLICATE_WINDOW:-24h}

args=(--server "${NATS_URL:-nats://127.0.0.1:4222}")
if [[ -n "${NATS_AUTH_TOKEN:-}" ]]; then
  args+=(--token "${NATS_AUTH_TOKEN}")
fi

if nats "${args[@]}" stream info "$STREAM" >/dev/null 2>&1; then
  nats "${args[@]}" stream edit "$STREAM" \
    --subjects "$SUBJECTS" \
    --storage file \
    --max-age "$MAX_AGE" \
    --dupe-window "$DUP_WINDOW" \
    --defaults
else
  nats "${args[@]}" stream add "$STREAM" \
    --subjects "$SUBJECTS" \
    --storage file \
    --retention limits \
    --max-age "$MAX_AGE" \
    --dupe-window "$DUP_WINDOW" \
    --defaults
fi
