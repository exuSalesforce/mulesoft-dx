#!/usr/bin/env bash
# Resolve a connector bundle to a directory the rest of the skill can read.
#
# Order of resolution (mirrors what the ACB plugin's ManifestRdsExtensionModelSource
# does — see go-connector-headless-descriptors.md §6):
#
#   1. $ACB_HOME/.cache/go/<name>/    — warm cache (the same dir the plugin uses)
#   2. RDS GET /v1/connectors/<name>/descriptor
#      → cached to $ACB_HOME/.cache/go/<name>/{extension-model.json,dsl.json,extension.xsd}
#
# The rest of the skill only sees a directory path. Caching to $ACB_HOME/.cache/go
# (the same place the plugin reads from on project-open) means a project we
# generate has its descriptors hot-cached for the canvas with no extra step.
#
# This skill ships no local connector bundles. To pre-populate the cache from
# RDS once (so subsequent picks succeed offline), run:
#   bash "$SKILL_DIR/scripts/seed_cache.sh" <name>...
#   bash "$SKILL_DIR/scripts/seed_cache.sh" --from-rds   # all connectors RDS reports
#
# Usage: fetch_bundle.sh <name>
#   exits 0 with the resolved directory path on stdout
#   exits 1 if no source yields a bundle
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
ACB_HOME="${ACB_HOME:-$HOME/AnypointCodeBuilder}"
ACB_CACHE_DIR="$ACB_HOME/.cache/go"

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "Usage: fetch_bundle.sh <name>" >&2
  exit 2
fi

# Validate name shape — same set ProjectManifest.java accepts. Path traversal
# and weird chars never reach RDS or the cache dir.
if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid connector name: '$NAME' (must match [A-Za-z0-9._-]+)" >&2
  exit 1
fi

# 1. Warm cache wins. Must have extension-model.json at minimum.
CACHED="$ACB_CACHE_DIR/$NAME"
if [[ -f "$CACHED/extension-model.json" ]]; then
  echo "$CACHED"
  exit 0
fi

# 2. RDS — single /descriptor call returns all three artifacts atomically.
RDS_JSON="$TMP_DIR/rds.json"
if [[ ! -f "$RDS_JSON" ]]; then
  echo "no warm cache for '$NAME' and no RDS endpoint recorded ($RDS_JSON missing)" >&2
  echo "  run \"$SKILL_DIR/scripts/ensure_rds.sh\" first to bring up RDS" >&2
  exit 1
fi

URL="$(jq -r .url "$RDS_JSON")"

DESC_TMP="$(mktemp)"
trap 'rm -f "$DESC_TMP"' EXIT

CODE="$(curl -sS -w '%{http_code}' -o "$DESC_TMP" --max-time 30 "$URL/v1/connectors/$NAME/descriptor" 2>>"$TMP_DIR/fetch_bundle.err" || echo "000")"
case "$CODE" in
  200) ;;
  404)
    echo "$URL/v1/connectors/$NAME/descriptor returned 404 — connector '$NAME' not loaded on RDS" >&2
    exit 1
    ;;
  *)
    echo "$URL/v1/connectors/$NAME/descriptor returned $CODE" >&2
    [[ -s "$DESC_TMP" ]] && echo "  body: $(head -c 200 "$DESC_TMP")" >&2
    exit 1
    ;;
esac

# Validate the response carries an extensionModel object — the only required field.
if ! jq -e '.extensionModel | type == "object"' "$DESC_TMP" >/dev/null 2>&1; then
  echo "RDS /descriptor for '$NAME' did not include an extensionModel object" >&2
  exit 1
fi

# Write through to $ACB_HOME/.cache/go/<name>/ — the same layout the plugin
# reads on project-open, so the canvas renders without re-fetching.
mkdir -p "$CACHED"
jq -c '.extensionModel' "$DESC_TMP" >"$CACHED/extension-model.json"
# dsl is optional; write only when present and non-null.
if jq -e '.dsl | type == "object"' "$DESC_TMP" >/dev/null 2>&1; then
  jq -c '.dsl' "$DESC_TMP" >"$CACHED/dsl.json"
fi
# xsd is a string; only write when non-empty.
XSD_LEN="$(jq -r '.xsd // "" | length' "$DESC_TMP")"
if [[ "$XSD_LEN" -gt 0 ]]; then
  jq -r '.xsd' "$DESC_TMP" >"$CACHED/extension.xsd"
fi
# .meta records what we cached; informational only — skill doesn't invalidate on it.
jq '{ name: .name, version: .version, fetchedAt: now | todate }' "$DESC_TMP" >"$CACHED/.meta"

echo "$CACHED"
