#!/usr/bin/env bash
# Phase 1 Step 2: ensure the real RemoteDesignService (RDS) is reachable.
#
# Probes MULE_DX_RDS_URL/healthz (default http://localhost:8090). On miss, brings
# up the real Go RDS via start_real_rds.sh — which under the hood defers to
# go-runtime/start-rds.sh. Idempotent: a healthy URL is reused as-is.
#
# This skill targets the real RDS only. There is no stub backend.
#
# Writes tmp/rds.json:
#   { "url": "...", "managed": false, "pid": null, "backend": "real" }
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
mkdir -p "$TMP_DIR"

RDS_JSON="$TMP_DIR/rds.json"
RDS_URL="${MULE_DX_RDS_URL:-http://localhost:8090}"

healthy() {
  local url="$1"
  curl -fsS --max-time 2 "$url/healthz" >/dev/null 2>&1
}

# Reuse path: existing record + still healthy.
if [[ -f "$RDS_JSON" ]]; then
  EXISTING_URL="$(jq -r '.url // empty' "$RDS_JSON" 2>/dev/null || true)"
  if [[ -n "$EXISTING_URL" ]] && healthy "$EXISTING_URL"; then
    echo "$RDS_JSON"
    exit 0
  fi
fi

# Direct hit on the configured URL (someone else already has RDS up).
if healthy "$RDS_URL"; then
  cat >"$RDS_JSON" <<JSON
{ "url": "$RDS_URL", "managed": false, "pid": null, "backend": "real" }
JSON
  echo "$RDS_JSON"
  exit 0
fi

# Bring up the real RDS stack. start_real_rds.sh writes tmp/rds.json itself
# and prints the path on success.
exec "$SKILL_DIR/scripts/start_real_rds.sh" "$@"
