#!/usr/bin/env bash
# Resolve a connector bundle to a directory the rest of the skill can read.
# Order of resolution:
#
#   1. fixtures/go-connectors/<name>/   — bundle shipped with the skill (offline)
#   2. RDS GET /v1/connectors/<name>/{extension-model,dsl}
#      → cached at tmp/connector-fetched/<name>/{extension-model.json,dsl.json}
#
# This is the bridge between "shipped with the skill" and "fetched live from
# the running RDS". The rest of the skill only sees a directory path; this
# script is the only place the choice happens.
#
# Usage: fetch_bundle.sh <name>
#   exits 0 with the resolved directory path on stdout
#   exits 1 if neither local fixture nor RDS yields a bundle
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "Usage: fetch_bundle.sh <name>" >&2
  exit 2
fi

# 1. Local fixture wins. extension-model.json must exist (it's the SoT for
# the skill's digest helper).
LOCAL="$SKILL_DIR/fixtures/go-connectors/$NAME"
if [[ -f "$LOCAL/extension-model.json" ]]; then
  echo "$LOCAL"
  exit 0
fi

# 2. Try RDS. tmp/rds.json must already point at a live RDS endpoint with
# /v1/connectors/{name}/{extension-model,dsl} implemented (the local Node stub
# returns 404 — that's expected, it's not a real RDS).
RDS_JSON="$TMP_DIR/rds.json"
if [[ ! -f "$RDS_JSON" ]]; then
  echo "no local fixture for '$NAME' and no RDS endpoint recorded ($RDS_JSON missing)" >&2
  echo "  run start_rds_stub.sh --real first, or copy the bundle into fixtures/go-connectors/$NAME/" >&2
  exit 1
fi

URL="$(jq -r .url "$RDS_JSON")"
BACKEND="$(jq -r '.backend // "unknown"' "$RDS_JSON")"
DEST="$TMP_DIR/connector-fetched/$NAME"
mkdir -p "$DEST"

fetch() {
  # $1 = path under URL, $2 = local target. Echoes nothing on success; on failure,
  # writes the response body + status to stderr and returns 1.
  local rel="$1" target="$2"
  local code
  code="$(curl -sS -w '%{http_code}' -o "$target" --max-time 10 "$URL$rel" 2>>"$TMP_DIR/fetch_bundle.err" || echo "000")"
  case "$code" in
    200) return 0 ;;
    404)
      echo "  $URL$rel returned 404 — connector '$NAME' not in RDS bundles dir (backend=$BACKEND)" >&2
      return 1 ;;
    *)
      echo "  $URL$rel returned $code" >&2
      [[ -s "$target" ]] && echo "  body: $(head -c 200 "$target")" >&2
      return 1 ;;
  esac
}

if ! fetch "/v1/connectors/$NAME/extension-model" "$DEST/extension-model.json"; then
  echo "fetch failed for '$NAME' (extension-model)" >&2
  rm -f "$DEST/extension-model.json"
  exit 1
fi

# dsl.json is required too — without it the digest helper can't surface DSL element
# names. If the endpoint is implemented but the file's missing on the RDS side,
# bail with a clear message.
if ! fetch "/v1/connectors/$NAME/dsl" "$DEST/dsl.json"; then
  echo "fetch failed for '$NAME' (dsl)" >&2
  rm -f "$DEST/extension-model.json" "$DEST/dsl.json"
  exit 1
fi

echo "$DEST"
