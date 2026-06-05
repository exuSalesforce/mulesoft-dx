#!/usr/bin/env bash
# Phase 1 Step 5: produce a Claude-readable digest of a picked connector.
#
# Reads tmp/connector-choices/<nick>.json, runs helpers/digest_extension_model.mjs
# against the bundle, then helpers/emit_metadata_files.mjs to split the digest into
# the per-shape file family the build-mule-integration skill produces (so any tool
# reading either skill's tmp/ shape works against ours too).
#
# Files written:
#   tmp/connector-metadata/<nick>-digest.json    — rich digest used internally by this skill
#   tmp/connector-metadata/<nick>.json           — flat reference (operations/sources/configs/errorTypes)
#   tmp/connector-metadata/<nick>-<op>.json      — per-operation deep metadata (one file per op/source)
#   tmp/connector-metadata/<nick>-config.json    — per-config metadata + connection-provider attributes
#   tmp/connector-errors/<nick>.json             — connector-wide errorTypes whitelist
#   tmp/connector-errors/<nick>.<op>.json        — per-operation errorTypes
#
# Usage: describe_connector.sh <nick>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

NICK="${1:-}"
if [[ -z "$NICK" ]]; then
  echo "Usage: describe_connector.sh <nick>" >&2
  exit 2
fi

CHOICE="$TMP_DIR/connector-choices/$NICK.json"
if [[ ! -f "$CHOICE" ]]; then
  echo "no pick at $CHOICE (run \"$SKILL_DIR/scripts/pick_connector.sh\" first)" >&2
  exit 1
fi

BUNDLE_SOURCE="$(jq -r '.bundleSource' "$CHOICE")"
PREFIX="$(jq -r '.prefix' "$CHOICE")"

mkdir -p "$TMP_DIR/connector-metadata" "$TMP_DIR/connector-errors"
DIGEST="$TMP_DIR/connector-metadata/$NICK-digest.json"

node "$SKILL_DIR/helpers/digest_extension_model.mjs" "$BUNDLE_SOURCE" >"$DIGEST"
node "$SKILL_DIR/helpers/emit_metadata_files.mjs" "$NICK" "$DIGEST" "$TMP_DIR" >/dev/null

# Compact stdout digest the agent reads to make trigger/provider decisions.
# Flatten parameters across all groups (a param's "group" is just layout — required-ness
# applies regardless), then list each op once with its required-param set. The XML
# element name comes from .element (sourced from dsl.json, not just the model `name`).
jq -r --arg nick "$NICK" --arg prefix "$PREFIX" '
  def required_names: [.parameterGroups[].parameters[] | select(.required) | .name];

  "## connector: \($nick) (prefix: \($prefix), namespace: \(.namespace))",
  "operations:",
  (.configurations[0].operations[]
    | (required_names) as $req
    | "  - \($prefix):\(.element)"
      + (if .requiresConnection then " [needs config]" else "" end)
      + (if ($req | length) > 0 then " required=" + ($req | join(",")) else "" end)),
  "sources:",
  (if (.configurations[0].sources | length) > 0
   then (.configurations[0].sources[] | (required_names) as $req
         | "  - \($prefix):\(.element)"
           + (if ($req | length) > 0 then " required=" + ($req | join(",")) else "" end))
   else "  (none)" end),
  "connection providers:",
  (.configurations[0].connectionProviders[]
    | (required_names) as $req
    | "  - element=\($prefix):\(.element) (provider name=\(.name)) required="
      + (if ($req | length) > 0 then ($req | join(",")) else "(none)" end)),
  "config element: \($prefix):\(.configurations[0].element)"
' "$DIGEST"

echo
echo "(rich digest:        $DIGEST)"
echo "(flat reference:     $TMP_DIR/connector-metadata/$NICK.json)"
echo "(per-op metadata:    $TMP_DIR/connector-metadata/$NICK-<op>.json)"
echo "(per-config:         $TMP_DIR/connector-metadata/$NICK-config.json)"
echo "(error whitelists:   $TMP_DIR/connector-errors/$NICK.json + $NICK.<op>.json)"
