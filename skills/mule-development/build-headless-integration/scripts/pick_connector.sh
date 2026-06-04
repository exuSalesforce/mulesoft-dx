#!/usr/bin/env bash
# Phase 1 Step 4 (cont.): record the agent's connector pick to tmp/connector-choices/<nick>.json.
#
# Pattern adapted from build-mule-integration/scripts/pick_connector.sh — same
# state-on-disk discipline, but the payload here is the bundle name + prefix
# (not a Maven GAV).
#
# Bundle resolution is delegated to fetch_bundle.sh, which prefers the local
# fixture under fixtures/go-connectors/<name>/ and falls back to RDS GET
# /v1/connectors/<name>/{extension-model,dsl} when the local fixture is absent
# and a real RDS is reachable. The rest of the skill only sees the resolved
# directory path through the bundleSource field of the choice JSON.
#
# Usage: pick_connector.sh <nick> <bundle-name>
#   nick         human-friendly slug the agent uses to refer to this pick (e.g. "salesforce")
#   bundle-name  connector identifier (matches a local fixture dir or a name RDS knows)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

NICK="${1:-}"
BUNDLE="${2:-}"

if [[ -z "$NICK" || -z "$BUNDLE" ]]; then
  echo "Usage: pick_connector.sh <nick> <bundle-name>" >&2
  exit 2
fi

# Resolve via fetch_bundle.sh — local fixture wins, RDS is the fallback.
BUNDLE_DIR="$("$SKILL_DIR/scripts/fetch_bundle.sh" "$BUNDLE")"
EM="$BUNDLE_DIR/extension-model.json"
if [[ ! -f "$EM" ]]; then
  echo "fetch_bundle.sh returned $BUNDLE_DIR but extension-model.json is missing" >&2
  exit 1
fi

mkdir -p "$TMP_DIR/connector-choices"
OUT="$TMP_DIR/connector-choices/$NICK.json"

NAME="$(jq -r '.name // ""' "$EM")"
VERSION="$(jq -r '.version // ""' "$EM")"
PREFIX="$(jq -r '.xmlDsl.prefix // ""' "$EM")"
NAMESPACE="$(jq -r '.xmlDsl.namespace // ""' "$EM")"
SCHEMA_LOCATION="$(jq -r '.xmlDsl.schemaLocation // ""' "$EM")"

cat >"$OUT" <<JSON
{
  "nick": "$NICK",
  "bundle": "$BUNDLE",
  "bundleSource": "$BUNDLE_DIR",
  "name": "$NAME",
  "version": "$VERSION",
  "prefix": "$PREFIX",
  "namespace": "$NAMESPACE",
  "schemaLocation": "$SCHEMA_LOCATION"
}
JSON

echo "$OUT"
