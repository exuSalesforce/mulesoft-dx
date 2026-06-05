#!/usr/bin/env bash
# Phase 2 Step 9 (first half): freeze the design from tmp/connector-choices/* +
# the agent-supplied spec into a single tmp/design-spec.json that
# create_versionless_project.sh will consume.
#
# The agent passes the project name, trigger spec, and per-connector connection
# choices via stdin as JSON, e.g.:
#   {
#     "projectName": "demo-sf-poller",
#     "muleVersion": "4.11.0",
#     "javaVersion": "17",
#     "trigger": { "kind": "scheduler", "frequency": 60000, "timeUnit": "MILLISECONDS" },
#     "connections": [
#       { "nick": "salesforce", "configName": "Salesforce_Config", "providerName": "basic" }
#     ]
#   }
#
# This script verifies each "nick" has a matching pick + describe artifact, then
# emits tmp/design-spec.json with the picks merged in.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"

if [[ -t 0 ]]; then
  echo "Usage: agent passes design spec JSON on stdin" >&2
  exit 2
fi

SPEC_IN="$(cat)"
SPEC_FILE="$TMP_DIR/design-spec.json"

# Validate input is JSON before doing anything else.
if ! printf '%s' "$SPEC_IN" | jq . >/dev/null 2>&1; then
  echo "design spec is not valid JSON" >&2
  exit 1
fi

PROJECT_NAME="$(printf '%s' "$SPEC_IN" | jq -r '.projectName // empty')"
if [[ -z "$PROJECT_NAME" ]]; then
  echo "design spec is missing .projectName" >&2
  exit 1
fi

# Collect picks: every nick in .connections must have tmp/connector-choices/<nick>.json
# and tmp/connector-metadata/<nick>.json on disk.
NICKS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  NICKS+=("$line")
done < <(printf '%s' "$SPEC_IN" | jq -r '.connections[]?.nick // empty')

if (( ${#NICKS[@]} == 0 )); then
  echo "design spec has no .connections[]" >&2
  exit 1
fi

PICKS_JSON="["
sep=""
for nick in "${NICKS[@]}"; do
  choice="$TMP_DIR/connector-choices/$nick.json"
  meta="$TMP_DIR/connector-metadata/$nick.json"
  if [[ ! -f "$choice" ]]; then
    echo "missing pick: $choice (run \"$SKILL_DIR/scripts/pick_connector.sh\" $nick <bundle>)" >&2
    exit 1
  fi
  if [[ ! -f "$meta" ]]; then
    echo "missing describe: $meta (run \"$SKILL_DIR/scripts/describe_connector.sh\" $nick)" >&2
    exit 1
  fi
  PICKS_JSON+="$sep$(cat "$choice")"
  sep=","
done
PICKS_JSON+="]"

printf '%s' "$SPEC_IN" \
  | jq --argjson picks "$PICKS_JSON" '. + {picks: $picks, committedAt: now | tostring}' \
  >"$SPEC_FILE"

echo "$SPEC_FILE"
