#!/usr/bin/env bash
# List which connectors are currently loaded by the running RDS / ConnectivityService.
#
# Calls GET /v1/connectors on the recorded RDS endpoint (tmp/rds.json). Useful for:
#   - Confirming the running stack actually loaded a connector you've picked
#     (the stub returns 404 on this endpoint; real RDS returns the actual list)
#   - Telling the user which connectors are available before they pick
#
# Usage: bash scripts/list_rds_connectors.sh
#   exits 0 with JSON list on stdout when RDS is the real backend
#   exits 0 with an empty list + a note on stderr when running against the stub
set -euo pipefail

WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
RDS_JSON="$TMP_DIR/rds.json"

if [[ ! -f "$RDS_JSON" ]]; then
  echo "no RDS endpoint recorded — run start_rds_stub.sh first" >&2
  exit 1
fi

URL="$(jq -r .url "$RDS_JSON")"
BACKEND="$(jq -r '.backend // "unknown"' "$RDS_JSON")"

# Probe /v1/connectors. Stub returns 404 (intentional — it doesn't proxy connector binaries);
# real RDS returns { "connectors": [...] }.
RESPONSE="$(curl -sS -w '\n%{http_code}' --max-time 5 "$URL/v1/connectors" 2>/dev/null || true)"
BODY="$(printf '%s\n' "$RESPONSE" | sed '$d')"
CODE="$(printf '%s\n' "$RESPONSE" | tail -1)"

case "$CODE" in
  200)
    echo "$BODY"
    ;;
  404)
    echo "/v1/connectors not implemented at $URL (backend=$BACKEND)" >&2
    echo "  this is expected for the local stub; only the real Go RDS implements it" >&2
    echo '{"connectors": []}'
    ;;
  *)
    echo "unexpected response $CODE from $URL/v1/connectors" >&2
    [[ -n "$BODY" ]] && echo "  body: $BODY" >&2
    exit 1
    ;;
esac
