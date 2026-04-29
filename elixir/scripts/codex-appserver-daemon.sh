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

CODEX_BIN=${CODEX_BIN:-codex}
CODEX_WS_HOST=${CODEX_WS_HOST:-127.0.0.1}
CODEX_WS_PORT=${CODEX_WS_PORT:-4500}
CODEX_WS_URL=${CODEX_WS_URL:-ws://${CODEX_WS_HOST}:${CODEX_WS_PORT}}
CODEX_APPSERVER_STATE_DIR=${CODEX_APPSERVER_STATE_DIR:-$HOME/.cache/codex}
CODEX_APPSERVER_PID_FILE=${CODEX_APPSERVER_PID_FILE:-${CODEX_APPSERVER_STATE_DIR}/appserver-${CODEX_WS_HOST}-${CODEX_WS_PORT}.pid}
CODEX_APPSERVER_LOG_FILE=${CODEX_APPSERVER_LOG_FILE:-${CODEX_APPSERVER_STATE_DIR}/appserver-${CODEX_WS_HOST}-${CODEX_WS_PORT}.log}
CODEX_APPSERVER_START_TIMEOUT_SEC=${CODEX_APPSERVER_START_TIMEOUT_SEC:-30}
CODEX_APPSERVER_EXTRA_ARGS=${CODEX_APPSERVER_EXTRA_ARGS:-}
CODEX_MODEL=${CODEX_MODEL:-gpt-5.5}
CODEX_MODEL_REASONING_EFFORT=${CODEX_MODEL_REASONING_EFFORT:-xhigh}

mkdir -p "$CODEX_APPSERVER_STATE_DIR"

is_port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$CODEX_WS_PORT" -sTCP:LISTEN -a -c codex >/dev/null 2>&1
  else
    return 1
  fi
}

is_pid_alive() {
  local pid=$1

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  return 1
}

if [ -f "$CODEX_APPSERVER_PID_FILE" ]; then
  pid=$(cat "$CODEX_APPSERVER_PID_FILE")
  if is_pid_alive "$pid"; then
    exit 0
  fi
  rm -f "$CODEX_APPSERVER_PID_FILE"
fi

if is_port_in_use; then
  echo "codex app-server is already listening on ws://$CODEX_WS_HOST:$CODEX_WS_PORT"
  exit 0
fi

command -v "$CODEX_BIN" >/dev/null 2>&1 || {
  echo "ERROR: CODEX_BIN '$CODEX_BIN' not found" >&2
  exit 1
}

set +e
printf "INFO: booting codex app-server via ws on %s\n" "$CODEX_WS_URL"

$CODEX_BIN app-server \
  --listen "$CODEX_WS_URL" \
  --config model="$CODEX_MODEL" \
  --config model_reasoning_effort="$CODEX_MODEL_REASONING_EFFORT" \
  --config shell_environment_policy.inherit=all \
  $CODEX_APPSERVER_EXTRA_ARGS \
  >>"$CODEX_APPSERVER_LOG_FILE" 2>&1 &
server_pid=$!
set -e

echo "$server_pid" > "$CODEX_APPSERVER_PID_FILE"

autostart_deadline=$((SECONDS + CODEX_APPSERVER_START_TIMEOUT_SEC))
while ((SECONDS < autostart_deadline)); do
  if is_pid_alive "$server_pid" && is_port_in_use; then
    exit 0
  fi

  if ! is_pid_alive "$server_pid"; then
    echo "ERROR: codex app-server exited immediately." >&2
    if [ -f "$CODEX_APPSERVER_LOG_FILE" ]; then
      tail -n 40 "$CODEX_APPSERVER_LOG_FILE"
    fi
    rm -f "$CODEX_APPSERVER_PID_FILE"
    exit 1
  fi

  sleep 1
 done

if is_pid_alive "$server_pid"; then
  echo "WARN: app-server started, but readiness check timed out (PID=$server_pid)"
  exit 0
fi

echo "ERROR: codex app-server not ready in time." >&2
rm -f "$CODEX_APPSERVER_PID_FILE"
exit 1
