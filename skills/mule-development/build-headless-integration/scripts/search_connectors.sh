#!/usr/bin/env bash
# Phase 1 Step 4: list Go connectors matching a search term.
#
# Catalog source is the running RDS — `GET /v1/connectors` returns every connector
# the ConnectivityService has loaded. This skill ships no local connector bundles;
# RDS is the single source of truth.
#
# Pickable filter: `/v1/connectors` lists *binaries* that can run, but the canvas
# only renders connectors that ALSO have a static descriptor (e.g. `http` is
# loaded but ships no descriptor today). This script probes
# `/v1/connectors/<name>/descriptor` per match and only emits the pickable ones.
# Non-pickable matches are reported on stderr so the caller still sees them.
#
# Filter is a case-insensitive substring match against the connector name. Output
# format (TSV, one row per pickable match):
#
#   <name>\t<operations-count>
#
# The agent picks a name and feeds it to pick_connector.sh, which fetches the
# connector's full descriptor (extension-model + dsl + xsd) from RDS.
set -euo pipefail

WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

TERM_ARG="${1:-}"
if [[ -z "$TERM_ARG" ]]; then
  echo "Usage: search_connectors.sh <term>" >&2
  exit 2
fi

RDS_JSON="$TMP_DIR/rds.json"
if [[ ! -f "$RDS_JSON" ]]; then
  echo "no RDS endpoint recorded ($RDS_JSON missing)" >&2
  echo "  run start_rds_stub.sh --real first" >&2
  exit 1
fi

URL="$(jq -r .url "$RDS_JSON")"
term_lc="$(printf '%s' "$TERM_ARG" | tr '[:upper:]' '[:lower:]')"

# Pull the catalog; on outage, surface that distinctly from "no matches".
if ! CATALOG="$(curl -fsS --max-time 5 "$URL/v1/connectors" 2>/dev/null)"; then
  echo "could not reach RDS at $URL" >&2
  exit 1
fi

# Substring filter first.
MATCHES="$(printf '%s' "$CATALOG" | jq -r --arg t "$term_lc" '
  .connectors[]
  | select((.name | ascii_downcase) | contains($t))
  | "\(.name)\t\(.operations | length)"
')"

if [[ -z "$MATCHES" ]]; then
  echo "no connectors on RDS match '$TERM_ARG'" >&2
  exit 1
fi

# Probe /descriptor per match. Pickable rows go to stdout; binary-only ones go to stderr.
PICKABLE=""
SKIPPED=""
while IFS=$'\t' read -r NAME OPS_COUNT; do
  [[ -z "$NAME" ]] && continue
  # GET (not HEAD) — Go's mux registered the route for GET only; HEAD returns 405.
  DESC_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$URL/v1/connectors/$NAME/descriptor" 2>/dev/null || echo "000")"
  if [[ "$DESC_CODE" == "200" ]]; then
    PICKABLE+="${NAME}	${OPS_COUNT}
"
  else
    SKIPPED+="  $NAME (no descriptor)
"
  fi
done <<< "$MATCHES"

if [[ -n "$SKIPPED" ]]; then
  printf 'skipped (loaded but not pickable — no descriptor on RDS):\n%s' "$SKIPPED" >&2
fi

if [[ -z "$PICKABLE" ]]; then
  echo "no pickable connectors match '$TERM_ARG' (binary-only matches listed above)" >&2
  exit 1
fi

printf '%s' "$PICKABLE"
