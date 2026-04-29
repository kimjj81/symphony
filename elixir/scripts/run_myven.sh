#!/usr/bin/env bash
set -euo pipefail

if [ -f .env.local ]; then
  set -a
  . .env.local
  set +a
elif [ -f .env ]; then
  set -a
  . .env
  set +a
fi

export SYMPHONY_CODEX_NETWORK_ACCESS="${SYMPHONY_CODEX_NETWORK_ACCESS:-true}"

mise trust
mise install
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.myven.md --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
