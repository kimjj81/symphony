#!/usr/bin/env bash
set -euo pipefail

for command_name in docker curl jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: Forgejo smoke requires $command_name" >&2
    exit 1
  fi
done

container_name="symphony-forgejo-smoke-$$"
admin_password="symphony-smoke-password"

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --name "$container_name" \
  --publish 127.0.0.1:3000:3000 \
  --env FORGEJO__database__DB_TYPE=sqlite3 \
  --env FORGEJO__security__INSTALL_LOCK=true \
  --env FORGEJO__server__ROOT_URL=http://127.0.0.1:3000/ \
  codeberg.org/forgejo/forgejo:16 >/dev/null

api_url="http://127.0.0.1:3000/api/v1"

for _attempt in $(seq 1 60); do
  if curl --silent --fail "${api_url}/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl --silent --fail "${api_url}/version" >/dev/null

docker exec --user git "$container_name" forgejo admin user create \
  --admin \
  --username symphony \
  --password "$admin_password" \
  --email symphony-smoke@example.invalid \
  --must-change-password=false >/dev/null

token_response=$(curl --silent --fail \
  --user "symphony:${admin_password}" \
  --header 'Content-Type: application/json' \
  --data '{"name":"symphony-smoke","scopes":["write:issue","write:repository"]}' \
  "${api_url}/users/symphony/tokens")
forgejo_token=$(printf '%s' "$token_response" | jq --raw-output '.sha1')

curl --silent --fail \
  --user "symphony:${admin_password}" \
  --header 'Content-Type: application/json' \
  --data '{"name":"smoke","auto_init":true,"default_branch":"main"}' \
  "${api_url}/user/repos" >/dev/null

SYMPHONY_RUN_FORGEJO_SMOKE=1 \
SYMPHONY_FORGEJO_SMOKE_API_URL="$api_url" \
SYMPHONY_FORGEJO_SMOKE_TOKEN="$forgejo_token" \
SYMPHONY_FORGEJO_SMOKE_OWNER=symphony \
SYMPHONY_FORGEJO_SMOKE_REPO=smoke \
${MIX:-mix} test test/symphony_elixir/forgejo_live_smoke_test.exs
