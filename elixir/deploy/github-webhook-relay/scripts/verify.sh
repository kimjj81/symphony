#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENV=${WEBHOOK_RELAY_VERIFY_VENV:-/tmp/symphony-webhook-relay-verify-venv}

python3 -m venv "$VENV"
# shellcheck disable=SC1091
. "$VENV/bin/activate"
python -m pip install -q -r "$ROOT/relay/requirements.txt"

python -m py_compile \
  "$ROOT/relay/app.py" \
  "$ROOT/relay/test_app.py"

PYTHONPATH="$ROOT/relay" python -m unittest "$ROOT/relay/test_app.py"

if command -v plutil >/dev/null 2>&1; then
  for plist in "$ROOT"/local/*.plist.example; do
    plutil -lint "$plist"
  done
fi

if [[ "${WEBHOOK_RELAY_VERIFY_K8S:-0}" == "1" ]] && command -v kubectl >/dev/null 2>&1; then
  for file in "$ROOT"/k8s/*.yaml; do
    case "$file" in
      *.example.yaml|*/nats-values.yaml) continue ;;
    esac
    kubectl apply --dry-run=client --validate=false -f "$file" >/dev/null
  done
fi

python - <<'PY' "$ROOT"
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
patterns = [
    re.compile(r"ghp_[A-Za-z0-9_]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"BEGIN (RSA|OPENSSH|EC) PRIVATE KEY"),
]
for path in root.rglob("*"):
    if not path.is_file() or path.name == "verify.sh":
        continue
    text = path.read_text(errors="ignore")
    for pattern in patterns:
        if pattern.search(text):
            print(f"Potential secret-like content found in {path}: {pattern.pattern}")
            raise SystemExit(1)
PY

echo "webhook relay kit verified"
