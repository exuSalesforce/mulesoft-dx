#!/usr/bin/env bash
# Stops the local RDS stub spawned by start_rds_stub.sh, if any.
# No-op if the recorded RDS URL came from MULE_DX_RDS_URL (managed=false).
set -euo pipefail

WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
RDS_JSON="$TMP_DIR/rds.json"

if [[ ! -f "$RDS_JSON" ]]; then
  exit 0
fi

MANAGED="$(jq -r '.managed // false' "$RDS_JSON" 2>/dev/null || echo "false")"
PID="$(jq -r '.pid // empty' "$RDS_JSON" 2>/dev/null || echo "")"

if [[ "$MANAGED" == "true" && -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
  kill -TERM "$PID" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$PID" 2>/dev/null; then
    kill -KILL "$PID" 2>/dev/null || true
  fi
fi

rm -f "$RDS_JSON" "$TMP_DIR/rds-stub.pid" "$TMP_DIR/rds-stub.port"
