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
export SYMPHONY_PORT="${SYMPHONY_PORT:-4000}"

ngrok_pid=""
webhook_registration_pid=""

cleanup() {
  status=$?
  set +e

  if [ -n "$webhook_registration_pid" ]; then
    kill "$webhook_registration_pid" 2>/dev/null
    wait "$webhook_registration_pid" 2>/dev/null
  fi

  if [ -n "$ngrok_pid" ]; then
    kill "$ngrok_pid" 2>/dev/null
    wait "$ngrok_pid" 2>/dev/null
  fi

  exit "$status"
}

require_command() {
  command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: %s is required for SYMPHONY_GITHUB_WEBHOOK_MODE=ngrok\n' "$command_name" >&2
    exit 1
  fi
}

ensure_github_webhook_secret() {
  secret_file="${SYMPHONY_GITHUB_WEBHOOK_SECRET_FILE:-$HOME/.config/symphony/myven-github-webhook-secret}"

  if [ -n "${SYMPHONY_GITHUB_WEBHOOK_SECRET:-}" ]; then
    export SYMPHONY_GITHUB_WEBHOOK_SECRET
    return
  fi

  mkdir -p "$(dirname "$secret_file")"

  if [ ! -s "$secret_file" ]; then
    umask 077
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$secret_file"
    else
      dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > "$secret_file"
      printf '\n' >> "$secret_file"
    fi
  fi

  SYMPHONY_GITHUB_WEBHOOK_SECRET="$(tr -d '\n' < "$secret_file")"
  export SYMPHONY_GITHUB_WEBHOOK_SECRET
}

start_ngrok() {
  require_command ngrok
  require_command curl

  ngrok_log="${SYMPHONY_NGROK_LOG:-$HOME/.cache/symphony/myven-ngrok.log}"
  mkdir -p "$(dirname "$ngrok_log")"

  ngrok http "$SYMPHONY_PORT" > "$ngrok_log" 2>&1 &
  ngrok_pid=$!

  for _ in $(seq 1 30); do
    public_url="$(
      curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
        | sed -n 's/.*"public_url":"\(https:[^"]*\)".*/\1/p' \
        | head -n 1
    )"

    if [ -n "$public_url" ]; then
      NGROK_URL="$public_url"
      return
    fi

    sleep 1
  done

  printf 'ERROR: timed out waiting for ngrok public HTTPS URL. See %s\n' "$ngrok_log" >&2
  exit 1
}

wait_for_symphony_api() {
  require_command curl

  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${SYMPHONY_PORT}/api/v1/state" >/dev/null 2>&1; then
      return
    fi

    sleep 1
  done

  printf 'ERROR: timed out waiting for Symphony API on port %s\n' "$SYMPHONY_PORT" >&2
  exit 1
}

register_github_webhook() {
  require_command gh

  webhook_url="$1"
  repo="${SYMPHONY_GITHUB_WEBHOOK_REPO:-studiojin-dev/myven}"
  hook_id_file="${SYMPHONY_GITHUB_WEBHOOK_ID_FILE:-$HOME/.cache/symphony/myven-github-webhook-id}"
  mkdir -p "$(dirname "$hook_id_file")"

  common_args=(
    -f name=web
    -f active=true
    -F events[]=issues
    -F events[]=pull_request
    -F events[]=pull_request_review
    -F events[]=issue_comment
    -f "config[url]=$webhook_url"
    -f "config[content_type]=json"
    -f "config[secret]=$SYMPHONY_GITHUB_WEBHOOK_SECRET"
  )

  if [ -s "$hook_id_file" ]; then
    hook_id="$(tr -d '\n' < "$hook_id_file")"
    if gh api --method PATCH "repos/${repo}/hooks/${hook_id}" "${common_args[@]}" >/dev/null; then
      printf 'Updated GitHub webhook %s -> %s\n' "$hook_id" "$webhook_url"
      return
    fi
  fi

  hook_id="$(gh api --method POST "repos/${repo}/hooks" "${common_args[@]}" --jq .id)"
  printf '%s\n' "$hook_id" > "$hook_id_file"
  printf 'Created GitHub webhook %s -> %s\n' "$hook_id" "$webhook_url"
}

register_github_webhook_after_symphony_starts() {
  wait_for_symphony_api
  register_github_webhook "${NGROK_URL}/api/v1/github/webhook"
}

mise trust
mise install
mise exec -- mix build

if [ "${SYMPHONY_GITHUB_WEBHOOK_MODE:-}" != "ngrok" ]; then
  exec mise exec -- ./bin/symphony ./WORKFLOW.myven.md --port "$SYMPHONY_PORT" --i-understand-that-this-will-be-running-without-the-usual-guardrails
fi

trap cleanup INT TERM EXIT

ensure_github_webhook_secret
start_ngrok

webhook_registration_log="${SYMPHONY_GITHUB_WEBHOOK_REGISTRATION_LOG:-$HOME/.cache/symphony/myven-github-webhook-registration.log}"
mkdir -p "$(dirname "$webhook_registration_log")"
printf 'GitHub webhook registration log: %s\n' "$webhook_registration_log"

register_github_webhook_after_symphony_starts > "$webhook_registration_log" 2>&1 &
webhook_registration_pid=$!

mise exec -- ./bin/symphony ./WORKFLOW.myven.md --port "$SYMPHONY_PORT" --i-understand-that-this-will-be-running-without-the-usual-guardrails
