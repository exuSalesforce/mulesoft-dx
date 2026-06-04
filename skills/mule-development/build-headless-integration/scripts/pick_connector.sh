#!/usr/bin/env bash
# Phase 1 Step 4 (cont.): record the agent's connector pick to tmp/connector-choices/<nick>.json.
#
# Pattern adapted from build-mule-integration/scripts/pick_connector.sh — same
# state-on-disk discipline, but the payload here is the bundle name + prefix
# (not a Maven GAV).
#
# Usage: pick_connector.sh <nick> <bundle-name>
#   nick         human-friendly slug the agent uses to refer to this pick (e.g. "salesforce")
#   bundle-name  directory under fixtures/go-connectors/ (e.g. "salesforce")
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

BUNDLE_DIR="$SKILL_DIR/fixtures/go-connectors/$BUNDLE"
EM="$BUNDLE_DIR/extension-model.json"
if [[ ! -f "$EM" ]]; then
  echo "no bundle at $BUNDLE_DIR (missing extension-model.json)" >&2
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
