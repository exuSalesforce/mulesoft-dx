#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 4 helper — fetch the full descriptor for one connector from the
# Remote Design Service and persist it under tmp/connector-metadata/.
#
# The descriptor is versionless and contains, in one response:
#   - namespace   (prefix + URI + schemaLocation)
#   - operations  (string array of operation names)
#   - sources     (string array of source names)
#   - configs     (each config with its connectionProviders fully expanded —
#                  attributes + childElements — so callers don't need a
#                  follow-up config-detail request)
#   - errorTypes  (connector-wide error type catalog)
#
# Usage:
#   scripts/describe_connector.sh <connector-id> [<nickname>]
#
# Where:
#   <connector-id>  — RDS id slug (e.g. "salesforce", "twilio", "http")
#   <nickname>      — optional short label used in filenames; defaults to <connector-id>
#
# Output:
#   tmp/connector-metadata/<nickname>.json   # full descriptor
#   tmp/connector-errors/<nickname>.json     # { "errorTypes": [...] } slice
#   stdout digest with namespace_prefix, configs[providers], operations
#   sample, sources sample, error_types — same shape as the predecessor
#   skill so any agent already trained on build-mule-integration's output
#   can read this without retraining.
#
# Exit code:
#   0  success
#   1  missing args / RDS unreachable / RDS returned non-2xx / response
#      missing required keys
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_rds_lib.sh
. "$SCRIPT_DIR/_rds_lib.sh"

usage() {
    echo "Usage: $0 <connector-id> [<nickname>]" >&2
    echo "  e.g. $0 salesforce" >&2
    echo "       $0 salesforce sfdc" >&2
}

CONNECTOR_ID="${1:-}"
if [ -z "$CONNECTOR_ID" ]; then
    usage
    exit 1
fi
NICKNAME="${2:-$CONNECTOR_ID}"

METADATA_DIR="${CONNECTOR_METADATA_DIR:-tmp/connector-metadata}"
ERRORS_DIR="${CONNECTOR_ERRORS_DIR:-tmp/connector-errors}"
mkdir -p "$METADATA_DIR" "$ERRORS_DIR"

OUT_JSON="$METADATA_DIR/${NICKNAME}.json"
ERR_JSON="$ERRORS_DIR/${NICKNAME}.json"

if ! rds_get "/connectors/${CONNECTOR_ID}" "$OUT_JSON"; then
    exit 1
fi

# Sanity-check the response shape — bail out early with a clear error
# rather than letting Step 9's scaffolder fail mysteriously when an
# expected field is missing.
if ! jq -e 'type == "object"' "$OUT_JSON" >/dev/null 2>&1; then
    echo "❌ Connector descriptor is not a JSON object" >&2
    cat "$OUT_JSON" >&2
    exit 1
fi
for required in namespace operations configs; do
    if ! jq -e --arg k "$required" 'has($k)' "$OUT_JSON" >/dev/null 2>&1; then
        echo "❌ Connector descriptor missing required field '$required'" >&2
        cat "$OUT_JSON" >&2
        exit 1
    fi
done

# Persist the connector-wide error-type whitelist as a compact slice so a
# future validator script can read it without re-parsing the whole
# descriptor.
jq '{errorTypes: (.errorTypes // [])}' "$OUT_JSON" > "$ERR_JSON"

echo "✅ $NICKNAME → $OUT_JSON"
echo "   errors → $ERR_JSON"
echo ""
echo "--- describe digest ---"
# operations and sources can run into the hundreds. Show counts and
# heads. configs include providers' names so Step 6 can ask the user
# which to use; full provider schemas are in the descriptor file.
jq -r '{
  namespace_prefix: (.namespace.prefix // .namespace),
  configs: (.configs // [] | map({
    name: .name,
    providers: ((.connectionProviders // []) | map(.name))
  })),
  operations_count: ((.operations // []) | length),
  operations_sample: ((.operations // []) | if length > 20 then .[0:20] + ["... (see " + "'"$OUT_JSON"'" + " for full list)"] else . end),
  sources_count: ((.sources // []) | length),
  sources_sample: ((.sources // []) | if length > 20 then .[0:20] + ["..."] else . end),
  error_types: (.errorTypes // [])
}' "$OUT_JSON"
