#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 5 helper — fetch one operation's full schema (attributes + child
# elements + error types) from the Remote Design Service. The scaffolder
# in Step 9 reads this file to assemble the operation's XML element with
# the exact attribute and child-element names the connector expects.
#
# Usage:
#   scripts/describe_operation.sh <connector-id> <operation-name> [<nickname>]
#
# Where:
#   <connector-id>    — RDS id slug (e.g. "salesforce", "twilio")
#   <operation-name>  — operation name from the connector's operations[]
#   <nickname>        — optional short label used in filenames; defaults to <connector-id>
#
# Output:
#   tmp/connector-metadata/<nickname>.<operation>.json   # full op schema
#   stdout digest summarising attributes (with required flags) and
#   childElements — the same shape build-mule-integration's
#   describe_connector.sh emits in --type operation mode.
#
# Exit code:
#   0  success
#   1  missing args / RDS unreachable / RDS returned non-2xx / response
#      missing required fields
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_rds_lib.sh
. "$SCRIPT_DIR/_rds_lib.sh"

usage() {
    echo "Usage: $0 <connector-id> <operation-name> [<nickname>]" >&2
    echo "  e.g. $0 salesforce query" >&2
    echo "       $0 salesforce query sfdc" >&2
}

CONNECTOR_ID="${1:-}"
OPERATION="${2:-}"
if [ -z "$CONNECTOR_ID" ] || [ -z "$OPERATION" ]; then
    usage
    exit 1
fi
NICKNAME="${3:-$CONNECTOR_ID}"

METADATA_DIR="${CONNECTOR_METADATA_DIR:-tmp/connector-metadata}"
mkdir -p "$METADATA_DIR"

# Path-encode the operation name. Twilio operations contain dots and
# hyphens (e.g. create20100401-accounts-messagesjson-by-account-sid)
# which are URL-safe, but jq's @uri keeps us safe against future names
# that contain spaces or unicode.
ENCODED_OP=$(printf '%s' "$OPERATION" | jq -sRr '@uri')

OUT_JSON="$METADATA_DIR/${NICKNAME}.${OPERATION}.json"

if ! rds_get "/connectors/${CONNECTOR_ID}/operations/${ENCODED_OP}" "$OUT_JSON"; then
    exit 1
fi

if ! jq -e 'type == "object"' "$OUT_JSON" >/dev/null 2>&1; then
    echo "❌ Operation descriptor is not a JSON object" >&2
    cat "$OUT_JSON" >&2
    exit 1
fi
for required in name elementName attributes; do
    if ! jq -e --arg k "$required" 'has($k)' "$OUT_JSON" >/dev/null 2>&1; then
        echo "❌ Operation descriptor missing required field '$required'" >&2
        cat "$OUT_JSON" >&2
        exit 1
    fi
done

echo "✅ $NICKNAME [$OPERATION] → $OUT_JSON"
echo ""
echo "--- describe digest (operation: $OPERATION) ---"
jq -r '{
  name: .name,
  prefix: (.prefix // null),
  elementName: .elementName,
  attributes: (.attributes // []),
  childElements: (.childElements // []),
  errorTypes: (.errorTypes // [])
}' "$OUT_JSON"
