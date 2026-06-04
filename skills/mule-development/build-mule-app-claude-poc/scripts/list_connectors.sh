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
mkdir -p "$(dirname "$OUT_FILE")"

if [ -n "$QUERY" ]; then
    # URL-encode the query value with jq (handles spaces, special chars)
    ENCODED=$(printf '%s' "$QUERY" | jq -sRr '@uri')
    PATH_AND_QUERY="/connectors?q=$ENCODED"
else
    PATH_AND_QUERY="/connectors"
fi

if ! rds_get "$PATH_AND_QUERY" "$OUT_FILE"; then
    exit 1
fi

if ! jq -e 'type == "array"' "$OUT_FILE" >/dev/null 2>&1; then
    echo "❌ Remote Design Service did not return a JSON array for $PATH_AND_QUERY" >&2
    cat "$OUT_FILE" >&2
    exit 1
fi

COUNT=$(jq 'length' "$OUT_FILE")
if [ "$COUNT" = "0" ]; then
    echo "No connectors matched '${QUERY:-<all>}'." >&2
    echo "   Either the Remote Design Service has no matching connector, or the search term is wrong." >&2
    exit 1
fi

echo "✅ $COUNT connector(s) → $OUT_FILE"
echo ""
echo "--- connectors ---"
# Right-pad id and name for readability. The script's stdout is what the
# agent reads when deciding which connector to pick (or which to surface
# in AskUserQuestion when the list has plausible variants).
jq -r '
  (max_by(.id | length).id | length) as $id_w |
  (max_by(.name | length).name | length) as $name_w |
  .[] | [
    (.id   | . + (" " * ($id_w   - length))),
    (.name | . + (" " * ($name_w - length))),
    .namespace
  ] | join("  ")
' "$OUT_FILE"
