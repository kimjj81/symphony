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
export SYMPHONY_GITHUB_WEBHOOK_URL="${SYMPHONY_GITHUB_WEBHOOK_URL:-https://ghook.windroamer.com/github}"

ngrok_pid=""
webhook_registration_pid=""
symphony_pid=""

cleanup() {
  status=$?
  trap - INT TERM EXIT
  set +e

  if [ -n "$webhook_registration_pid" ]; then
    kill "$webhook_registration_pid" 2>/dev/null
    wait "$webhook_registration_pid" 2>/dev/null
  fi

  if [ -n "$symphony_pid" ]; then
    kill "$symphony_pid" 2>/dev/null
    wait "$symphony_pid" 2>/dev/null
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
    printf 'ERROR: %s is required for GitHub webhook registration\n' "$command_name" >&2
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

  ngrok http "http://127.0.0.1:${SYMPHONY_PORT}" > "$ngrok_log" 2>&1 &
  ngrok_pid=$!

  for _ in $(seq 1 30); do
    public_url="$(
      curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
        | sed -n 's/.*"public_url":"\(https:[^"]*\)".*/\1/p' \
        | head -n 1 \
        || true
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
  webhook_url="$1"
  repo="${SYMPHONY_GITHUB_WEBHOOK_REPO:-studiojin-dev/myven}"
  hook_id_file="${SYMPHONY_GITHUB_WEBHOOK_ID_FILE:-$HOME/.cache/symphony/myven-github-webhook-id}"
  last_webhook_registration_error=""
  mkdir -p "$(dirname "$hook_id_file")"

  common_args=(
    -f name=web
    -F active=true
    -F events[]=issues
    -F events[]=pull_request
    -F events[]=pull_request_review
    -F events[]=pull_request_review_comment
    -F events[]=pull_request_review_thread
    -F events[]=issue_comment
    -f "config[url]=$webhook_url"
    -f "config[content_type]=json"
    -f "config[secret]=$SYMPHONY_GITHUB_WEBHOOK_SECRET"
  )

  if [ -s "$hook_id_file" ]; then
    hook_id="$(tr -d '\n' < "$hook_id_file")"
    if patch_output="$(gh api --method PATCH "repos/${repo}/hooks/${hook_id}" "${common_args[@]}" 2>&1)"; then
      printf 'Updated GitHub webhook %s -> %s\n' "$hook_id" "$webhook_url"
      return
    fi

    last_webhook_registration_error="$patch_output"
    printf '%s\n' "$patch_output" >&2
  fi

  if ! create_output="$(gh api --method POST "repos/${repo}/hooks" "${common_args[@]}" --jq .id 2>&1)"; then
    last_webhook_registration_error="$create_output"
    printf '%s\n' "$create_output" >&2
    return 1
  fi

  hook_id="$create_output"
  printf '%s\n' "$hook_id" > "$hook_id_file"
  printf 'Created GitHub webhook %s -> %s\n' "$hook_id" "$webhook_url"
}

report_github_webhook_status() {
  message="$1"
  printf '%s\n' "$message" >&2
  printf '%s\n' "$message" >&3
}

register_github_webhook_with_retry() {
  webhook_url="$1"
  retry_seconds="${SYMPHONY_GITHUB_WEBHOOK_RETRY_SECONDS:-30}"
  attempt=1
  retry_sleep_pid=""

  trap 'if [ -n "$retry_sleep_pid" ]; then kill "$retry_sleep_pid" 2>/dev/null; fi; exit 0' INT TERM

  while ! register_github_webhook "$webhook_url"; do
    case "$last_webhook_registration_error" in
      *"HTTP 503"*)
        failure_summary="GitHub API 장애 감지(HTTP 503)"
        ;;
      *"HTTP 5"[0-9][0-9]*)
        failure_summary="GitHub API 서버 장애 감지(HTTP 5xx)"
        ;;
      *)
        failure_summary="GitHub webhook 등록 실패"
        ;;
    esac

    report_github_webhook_status \
      "WARNING: ${failure_summary}; Symphony는 계속 실행 중이며 ${retry_seconds}초 후 재시도합니다 (시도 ${attempt})."
    attempt=$((attempt + 1))
    sleep "$retry_seconds" &
    retry_sleep_pid=$!
    wait "$retry_sleep_pid"
    retry_sleep_pid=""
  done

  failed_attempts=$((attempt - 1))
  if [ "$failed_attempts" -eq 0 ]; then
    report_github_webhook_status "INFO: GitHub webhook 등록 완료."
  else
    report_github_webhook_status \
      "INFO: GitHub webhook 등록 복구 완료 (실패 ${failed_attempts}회 후)."
  fi
}

register_github_webhook_after_symphony_starts() {
  wait_for_symphony_api
  register_github_webhook_with_retry "${NGROK_URL}/api/v1/github/webhook"
}

register_fixed_github_webhook() {
  register_github_webhook_with_retry "$SYMPHONY_GITHUB_WEBHOOK_URL"
}

start_github_webhook_registration() {
  webhook_registration_log="${SYMPHONY_GITHUB_WEBHOOK_REGISTRATION_LOG:-$HOME/.cache/symphony/myven-github-webhook-registration.log}"
  mkdir -p "$(dirname "$webhook_registration_log")"
  printf 'GitHub webhook registration log: %s\n' "$webhook_registration_log"

  "$@" 3>&2 > "$webhook_registration_log" 2>&1 &
  webhook_registration_pid=$!
}

run_symphony_managed() {
  mise exec -- ./bin/symphony ./WORKFLOW.myven.md --port "$SYMPHONY_PORT" --i-understand-that-this-will-be-running-without-the-usual-guardrails &
  symphony_pid=$!

  if wait "$symphony_pid"; then
    symphony_status=0
  else
    symphony_status=$?
  fi

  symphony_pid=""
  return "$symphony_status"
}

mise trust
mise install
mise exec -- mix build

trap cleanup INT TERM EXIT

case "${SYMPHONY_GITHUB_WEBHOOK_MODE:-}" in
  ""|none)
    exec mise exec -- ./bin/symphony ./WORKFLOW.myven.md --port "$SYMPHONY_PORT" --i-understand-that-this-will-be-running-without-the-usual-guardrails
    ;;
  fixed|ghook|relay)
    require_command gh
    ensure_github_webhook_secret
    start_github_webhook_registration register_fixed_github_webhook
    run_symphony_managed
    exit $?
    ;;
  ngrok)
    ;;
  *)
    printf 'ERROR: unsupported SYMPHONY_GITHUB_WEBHOOK_MODE=%s; use none, fixed, ghook, relay, or ngrok\n' "$SYMPHONY_GITHUB_WEBHOOK_MODE" >&2
    exit 1
    ;;
esac

ensure_github_webhook_secret
start_ngrok
require_command gh
start_github_webhook_registration register_github_webhook_after_symphony_starts
run_symphony_managed
