#!/usr/bin/env bash
# List connectors RDS knows about, annotated by whether each one is "pickable" —
# i.e. has a static descriptor available at /v1/connectors/<name>/descriptor.
#
# Two source-of-truth lists exist on RDS, with different meanings:
#   GET /v1/connectors                — connector binaries the runtime can execute (test-connection target)
#   GET /v1/connectors/{name}/descriptor — connector descriptors the canvas can render
# A name in the first list without a descriptor (e.g. http today) shows up in the
# canvas as Unknown — the skill should not pick those. This script flags it.
#
# Output: each connector on its own line:
#   <name>\t<operations-count>\t<pickable: yes|no>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
RDS_JSON="$TMP_DIR/rds.json"

if [[ ! -f "$RDS_JSON" ]]; then
  echo "no RDS endpoint recorded — run \"$SKILL_DIR/scripts/ensure_rds.sh\" first" >&2
  exit 1
fi

URL="$(jq -r .url "$RDS_JSON")"

# Pull the binary list.
RESPONSE="$(curl -sS -w '\n%{http_code}' --max-time 5 "$URL/v1/connectors" 2>/dev/null || true)"
BODY="$(printf '%s\n' "$RESPONSE" | sed '$d')"
CODE="$(printf '%s\n' "$RESPONSE" | tail -1)"

if [[ "$CODE" != "200" ]]; then
  echo "unexpected response $CODE from $URL/v1/connectors" >&2
  [[ -n "$BODY" ]] && echo "  body: $BODY" >&2
  exit 1
fi

# Per-name HEAD to /descriptor distinguishes pickable from binary-only. Cheap —
# RDS doesn't actually serve the body for HEAD, just the status code.
while IFS=$'\t' read -r NAME OPS_COUNT; do
  [[ -z "$NAME" ]] && continue
  # GET (not HEAD) because Go's mux registered the route for GET only — HEAD returns 405.
  # We only read the status code, so curl drops the body via -o /dev/null.
  DESC_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$URL/v1/connectors/$NAME/descriptor" 2>/dev/null || echo "000")"
  if [[ "$DESC_CODE" == "200" ]]; then
    PICKABLE="yes"
  else
    PICKABLE="no (no descriptor)"
  fi
  printf '%s\t%s\t%s\n' "$NAME" "$OPS_COUNT" "$PICKABLE"
done < <(printf '%s' "$BODY" | jq -r '.connectors[] | "\(.name)\t\(.operations | length)"')
