#!/usr/bin/env bash
set -euo pipefail

load_env_file() {
  local file=$1

  if [ -f "$file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a
  fi
}

if [ -n "${CODEX_APPSERVER_ENV:-}" ]; then
  load_env_file "$CODEX_APPSERVER_ENV"
else
  load_env_file "${XDG_CONFIG_HOME:-$HOME/.config}/codex/appserver.env"
  load_env_file "$HOME/.codex/appserver.env"
  load_env_file ".env"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

CODEX_BIN=${CODEX_BIN:-codex}
CODEX_WS_HOST=${CODEX_WS_HOST:-127.0.0.1}
CODEX_WS_PORT=${CODEX_WS_PORT:-4500}
CODEX_WS_URL=${CODEX_WS_URL:-ws://${CODEX_WS_HOST}:${CODEX_WS_PORT}}
CODEX_APPSERVER_DAEMON=${CODEX_APPSERVER_DAEMON:-$SCRIPT_DIR/codex-appserver-daemon.sh}

"$CODEX_APPSERVER_DAEMON"

if [ "${1:-}" = "app" ]; then
  exec "$CODEX_BIN" "$@"
fi

exec "$CODEX_BIN" --remote "$CODEX_WS_URL" "$@"
