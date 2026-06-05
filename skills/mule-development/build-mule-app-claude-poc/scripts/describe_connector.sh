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
XSD_FILE="$METADATA_DIR/${NICKNAME}.xsd"

if ! rds_get "/connectors/${CONNECTOR_ID}/descriptor" "$OUT_JSON"; then
    exit 1
fi

# Sanity-check the response shape. The Go-runtime RDS returns
#   { "name": "...", "version": "...", "extensionModel": {...}, "dsl": {...}, "xsd": "<xs:schema...>" }
# extensionModel + dsl + xsd are the three artifacts the scaffolder needs.
if ! jq -e 'type == "object"' "$OUT_JSON" >/dev/null 2>&1; then
    echo "❌ Connector descriptor is not a JSON object" >&2
    cat "$OUT_JSON" >&2
    exit 1
fi
for required in extensionModel dsl xsd; do
    if ! jq -e --arg k "$required" 'has($k)' "$OUT_JSON" >/dev/null 2>&1; then
        echo "❌ Connector descriptor missing required field '$required'" >&2
        cat "$OUT_JSON" >&2
        exit 1
    fi
done

# Pull the XSD out into its own file so xmllint can validate the
# scaffolded XML against it later.
jq -r '.xsd' "$OUT_JSON" > "$XSD_FILE"

# Persist the connector-wide error-type whitelist as a compact slice so a
# future validator script can read it without re-parsing the whole
# descriptor.
jq '{errorTypes: (.extensionModel.errors // [] | map(.type))}' "$OUT_JSON" > "$ERR_JSON"

echo "✅ $NICKNAME → $OUT_JSON"
echo "   xsd    → $XSD_FILE"
echo "   errors → $ERR_JSON"
echo ""
echo "--- describe digest ---"
# Twilio has 196 ops; show name + count, sample first 20.
jq '{
  name:    .name,
  version: .version,
  namespace_prefix: (.extensionModel.xmlDsl.prefix // null),
  namespace_uri:    (.extensionModel.xmlDsl.namespace // null),
  schema_location:  (.extensionModel.xmlDsl.schemaLocation // null),
  configs: (.extensionModel.configurations // [] | map({
    name: .name,
    providers: ((.connectionProviders // []) | map(.name))
  })),
  operations_count: ((.extensionModel.configurations[0].operationModels // []) | length),
  operations_sample: (
    (.extensionModel.configurations[0].operationModels // [])
    | map(.name)
    | if length > 20 then .[0:20] + ["... (see " + $out + " for the full list)"] else . end
  ),
  sources_count: ((.extensionModel.configurations[0].sourceModels // []) | length),
  sources_sample: (
    (.extensionModel.configurations[0].sourceModels // [])
    | map(.name)
    | if length > 20 then .[0:20] + ["..."] else . end
  ),
  error_types: (.extensionModel.errors // [] | map(.type))
}' --arg out "$OUT_JSON" "$OUT_JSON"
