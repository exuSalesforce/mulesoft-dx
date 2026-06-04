#!/usr/bin/env bash
# Phase 1 Step 2: ensure an RDS endpoint is reachable.
#
# Three backends, picked in order:
#   1. --real / MULE_DX_USE_REAL_RDS=1 / MULE_DX_RDS_BACKEND=real
#      → defer to scripts/start_real_rds.sh (which calls go-runtime/start-rds.sh).
#        Requires Docker + go-runtime checkout. Tests against real connector binaries.
#   2. MULE_DX_RDS_URL set externally
#      → trust it: probe /healthz and record. Same path whether it's the real RDS,
#        an in-process test stub, or a user-managed instance.
#   3. (default) spawn helpers/rds_stub.mjs locally
#      → wire-faithful Node stub that returns deterministic responses. No Docker, no
#        go-runtime. Right for offline / Demo 2 walkthroughs.
#
# Idempotent: if tmp/rds.json already points at a healthy URL, nothing changes.
#
# Writes tmp/rds.json:
#   { "url": "...", "managed": true|false, "pid": <num|null>, "backend": "stub"|"external"|"real" }
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
mkdir -p "$TMP_DIR"

RDS_JSON="$TMP_DIR/rds.json"

# Backend selection: --real flag, env vars, or default (stub).
WANT_REAL=""
if [[ "${1:-}" == "--real" ]] || [[ "${MULE_DX_USE_REAL_RDS:-}" == "1" ]] || [[ "${MULE_DX_RDS_BACKEND:-}" == "real" ]]; then
  WANT_REAL=1
fi

healthy() {
  local url="$1"
  curl -fsS --max-time 2 "$url/healthz" >/dev/null 2>&1
}

# Reuse path: existing record + still healthy + same backend the caller asked for.
# Asking for --real when the existing record is the stub (or vice versa) forces a switch.
if [[ -f "$RDS_JSON" ]]; then
  EXISTING_URL="$(jq -r '.url // empty' "$RDS_JSON" 2>/dev/null || true)"
  EXISTING_BACKEND="$(jq -r '.backend // "stub"' "$RDS_JSON" 2>/dev/null || echo "stub")"
  WANT_BACKEND="${WANT_REAL:+real}"
  WANT_BACKEND="${WANT_BACKEND:-stub}"
  if [[ -n "$EXISTING_URL" ]] && healthy "$EXISTING_URL" && [[ "$EXISTING_BACKEND" == "$WANT_BACKEND" || ( -z "$WANT_REAL" && "$EXISTING_BACKEND" == "external" ) ]]; then
    echo "$RDS_JSON"
    exit 0
  fi
  # Backend mismatch — tear down the wrong-backend stub before starting the right one.
  if [[ "$EXISTING_BACKEND" == "stub" ]] && [[ -n "$WANT_REAL" ]]; then
    "$SKILL_DIR/scripts/stop_rds_stub.sh" >/dev/null 2>&1 || true
  fi
fi

# Real-RDS path: defer to start_real_rds.sh (go-runtime/start-rds.sh under the hood).
if [[ -n "$WANT_REAL" ]]; then
  exec "$SKILL_DIR/scripts/start_real_rds.sh"
fi

# External RDS path: trust MULE_DX_RDS_URL if it answers /healthz.
if [[ -n "${MULE_DX_RDS_URL:-}" ]]; then
  if healthy "$MULE_DX_RDS_URL"; then
    cat >"$RDS_JSON" <<JSON
{ "url": "$MULE_DX_RDS_URL", "managed": false, "pid": null, "backend": "external" }
JSON
    echo "$RDS_JSON"
    exit 0
  fi
  echo "MULE_DX_RDS_URL=$MULE_DX_RDS_URL is set but /healthz did not answer" >&2
  exit 1
fi

# Local stub path: spawn helpers/rds_stub.mjs.
PID_FILE="$TMP_DIR/rds-stub.pid"
PORT_FILE="$TMP_DIR/rds-stub.port"
LOG_FILE="$TMP_DIR/rds-stub.log"

# If an old pid is still alive, reuse.
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null && [[ -f "$PORT_FILE" ]]; then
    URL="http://127.0.0.1:$(cat "$PORT_FILE")"
    if healthy "$URL"; then
      cat >"$RDS_JSON" <<JSON
{ "url": "$URL", "managed": true, "pid": $OLD_PID }
JSON
      echo "$RDS_JSON"
      exit 0
    fi
  fi
fi

# Fresh spawn.
PID_FILE="$PID_FILE" PORT_FILE="$PORT_FILE" LOG_FILE="$LOG_FILE" \
  nohup node "$SKILL_DIR/helpers/rds_stub.mjs" >>"$LOG_FILE" 2>&1 &
SPAWN_PID=$!

# Wait for the port file (the stub writes it as soon as it's listening).
for _ in $(seq 1 50); do
  if [[ -f "$PORT_FILE" ]]; then break; fi
  sleep 0.1
done

if [[ ! -f "$PORT_FILE" ]]; then
  echo "rds_stub failed to start; see $LOG_FILE" >&2
  exit 1
fi

URL="http://127.0.0.1:$(cat "$PORT_FILE")"
PID="$(cat "$PID_FILE" 2>/dev/null || echo "$SPAWN_PID")"

if ! healthy "$URL"; then
  echo "rds_stub at $URL is not healthy; see $LOG_FILE" >&2
  exit 1
fi

cat >"$RDS_JSON" <<JSON
{ "url": "$URL", "managed": true, "pid": $PID, "backend": "stub" }
JSON

echo "$RDS_JSON"
