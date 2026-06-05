#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 3 helper — list connectors known to the Remote Design Service,
# optionally filtered by query string. Versionless: no version, no GAV.
#
# Usage:
#   scripts/list_connectors.sh                    # full catalog
#   scripts/list_connectors.sh salesforce         # filtered
#
# Output:
#   - Writes the full JSON array to tmp/connectors-list.json
#   - Prints a compact digest to stdout, one connector per line:
#       <id>     <name>     <namespace>
#
# Exit code:
#   0  ≥1 connector returned and written to disk
#   1  zero results, RDS unreachable, or RDS returned a non-2xx
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_rds_lib.sh
. "$SCRIPT_DIR/_rds_lib.sh"

QUERY="${1:-}"
OUT_FILE="${LIST_CONNECTORS_OUT:-tmp/connectors-list.json}"
RAW_FILE="${OUT_FILE%.json}.raw.json"
mkdir -p "$(dirname "$OUT_FILE")"

# The Go-runtime RDS does not implement server-side filtering — it always
# returns the full catalog. We fetch the catalog and filter client-side
# below.
if ! rds_get "/connectors" "$RAW_FILE"; then
    exit 1
fi

# Response shape is { "connectors": [{ "name": "salesforce", "operations": [...] }, ...] }.
# Unwrap to a flat array so downstream callers don't have to know about the
# envelope.
if ! jq -e '.connectors | type == "array"' "$RAW_FILE" >/dev/null 2>&1; then
    echo "❌ Remote Design Service /connectors response missing .connectors array" >&2
    cat "$RAW_FILE" >&2
    exit 1
fi

if [ -n "$QUERY" ]; then
    QUERY_LOWER=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')
    jq --arg q "$QUERY_LOWER" '
        .connectors
        | map(select((.name | ascii_downcase) | contains($q)))
    ' "$RAW_FILE" > "$OUT_FILE"
else
    jq '.connectors' "$RAW_FILE" > "$OUT_FILE"
fi

COUNT=$(jq 'length' "$OUT_FILE")
if [ "$COUNT" = "0" ]; then
    echo "No connectors matched '${QUERY:-<all>}'." >&2
    echo "   The Remote Design Service catalog contains:" >&2
    jq -r '.connectors[] | "    - " + .name' "$RAW_FILE" >&2
    exit 1
fi

echo "✅ $COUNT connector(s) → $OUT_FILE"
echo ""
echo "--- connectors ---"
# Columns: <name>  <ops-count>. The list endpoint does not carry a
# description/namespace — those live in the per-connector descriptor.
jq -r '
  (max_by(.name | length).name | length) as $name_w |
  .[] | [
    (.name | . + (" " * ($name_w - length))),
    ((.operations | length | tostring) + " operations")
  ] | join("  ")
' "$OUT_FILE"
