#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 7 helper — consolidate Phase-1 discovery state into a single
# human-readable spec the user can review at Step 8 and a JSON sidecar
# the scaffolder reads at Step 9.
#
# Inputs (read from disk):
#   <spec-inputs.json>                       — passed as $1, captures user choices
#                                              (project name, source/target/trigger,
#                                              SOQL, body template, etc.)
#   tmp/connector-metadata/<nick>.json       — connector descriptor
#   tmp/connector-metadata/<nick>.<op>.json  — per-operation schema
#
# Outputs:
#   tmp/spec/<project-name>.md     — Markdown summary echoed to the user
#   tmp/spec/<project-name>.json   — JSON sidecar consumed by Step 9
#
# spec-inputs.json shape:
#   {
#     "projectName": "salesforce-accounts-to-twilio",
#     "summary":     "Queries top N Salesforce accounts and sends a combined SMS via Twilio.",
#     "trigger": {
#       "type": "http-listener",
#       "method": "POST",
#       "path": "/ops/salesforce-accounts-to-twilio"
#     },
#     "source": {
#       "connectorId": "salesforce",
#       "nickname":    "salesforce",
#       "config":      { "name": "salesforceConfig",  "provider": "basic" },
#       "operation":   "query",
#       "params":      { "soql": "SELECT Id, Name, Industry FROM Account LIMIT 5" }
#     },
#     "target": {
#       "connectorId": "twilio",
#       "nickname":    "twilio",
#       "config":      { "name": "twilioConfig", "provider": "account-sid-auth-token" },
#       "operation":   "create20100401-accounts-messagesjson-by-account-sid",
#       "params":      { "bodyTemplate": "Top {{count}} accounts:\n{{accountList}}" }
#     }
#   }
#
# spec sidecar shape (tmp/spec/<project>.json):
#   { ...spec-inputs.json, "connectors": { ...resolved metadata } }
#
# The scaffolder uses the resolved `connectors` block — not spec-inputs —
# so it never has to re-read the metadata files.
#
# Exit code:
#   0  success
#   1  missing args / missing metadata file / spec inputs invalid
set -euo pipefail

usage() {
    echo "Usage: $0 <spec-inputs.json>" >&2
    echo "  e.g. $0 tmp/spec-inputs.json" >&2
}

INPUTS="${1:-}"
if [ -z "$INPUTS" ]; then
    usage
    exit 1
fi
if [ ! -f "$INPUTS" ]; then
    echo "❌ spec inputs file not found: $INPUTS" >&2
    exit 1
fi
if ! jq -e 'type == "object"' "$INPUTS" >/dev/null 2>&1; then
    echo "❌ spec inputs is not a JSON object: $INPUTS" >&2
    exit 1
fi

METADATA_DIR="${CONNECTOR_METADATA_DIR:-tmp/connector-metadata}"
SPEC_DIR="${SPEC_DIR:-tmp/spec}"
mkdir -p "$SPEC_DIR"

PROJECT_NAME=$(jq -r '.projectName // empty' "$INPUTS")
if [ -z "$PROJECT_NAME" ]; then
    echo "❌ spec inputs missing required field: projectName" >&2
    exit 1
fi

# Helper: resolve a single connector's metadata + the operation slice and
# emit a JSON object suitable for the spec sidecar's `connectors.<role>`
# block.
resolve_role() {
    local role="$1"   # "source" | "target" | "trigger"
    local role_obj
    role_obj=$(jq --arg r "$role" '.[$r] // empty' "$INPUTS")
    if [ -z "$role_obj" ] || [ "$role_obj" = "null" ]; then
        printf 'null'
        return
    fi

    local connector_id nickname operation
    connector_id=$(printf '%s' "$role_obj" | jq -r '.connectorId // empty')
    nickname=$(printf '%s' "$role_obj"     | jq -r '.nickname // empty')
    operation=$(printf '%s' "$role_obj"    | jq -r '.operation // empty')

    if [ -z "$nickname" ]; then
        nickname="$connector_id"
    fi

    # The HTTP-listener trigger doesn't always require a connector descriptor
    # (the http connector is always in scope for this POC), but if the user
    # picked it explicitly we still try to pull metadata.
    local descriptor_file="$METADATA_DIR/${nickname}.json"
    local op_file="$METADATA_DIR/${nickname}.${operation}.json"

    local descriptor='null'
    if [ -f "$descriptor_file" ]; then
        descriptor=$(cat "$descriptor_file")
    elif [ -n "$connector_id" ]; then
        echo "⚠️  No descriptor at $descriptor_file — run describe_connector.sh first." >&2
    fi

    local op_schema='null'
    if [ -n "$operation" ] && [ -f "$op_file" ]; then
        op_schema=$(cat "$op_file")
    elif [ -n "$operation" ]; then
        echo "⚠️  No operation schema at $op_file — run describe_operation.sh first." >&2
    fi

    jq -n \
        --argjson role_obj "$role_obj" \
        --argjson descriptor "$descriptor" \
        --argjson op_schema "$op_schema" \
        '{
            connectorId: ($role_obj.connectorId // null),
            nickname:    ($role_obj.nickname    // $role_obj.connectorId // null),
            namespace:   ($descriptor.namespace // null),
            config:      ($role_obj.config      // null),
            operation:   ($role_obj.operation   // null),
            params:      ($role_obj.params      // {}),
            connectionProvider: (
                if ($descriptor // null) == null then null
                else (
                    ($descriptor.configs // [])[]?
                    | select(.name == ($role_obj.config.name // ""))
                    | (.connectionProviders // [])[]?
                    | select(.name == ($role_obj.config.provider // ""))
                ) // (
                    # fallback: first config + first provider when config name is unknown
                    ($descriptor.configs[0]?.connectionProviders[0]?) // null
                )
            ),
            operationSchema: $op_schema,
            errorTypes: ($descriptor.errorTypes // [])
        }'
}

SOURCE_BLOCK=$(resolve_role source)
TARGET_BLOCK=$(resolve_role target)
TRIGGER_BLOCK=$(resolve_role trigger)

SIDECAR_JSON="$SPEC_DIR/${PROJECT_NAME}.json"
SIDECAR_MD="$SPEC_DIR/${PROJECT_NAME}.md"

jq -n \
    --slurpfile inputs "$INPUTS" \
    --argjson source  "$SOURCE_BLOCK" \
    --argjson target  "$TARGET_BLOCK" \
    --argjson trigger "$TRIGGER_BLOCK" \
    '$inputs[0] + {
        connectors: {
            source:  $source,
            target:  $target,
            trigger: $trigger
        }
    }' > "$SIDECAR_JSON"

# Build the human-readable spec. Markdown is generated from the sidecar so
# the two are guaranteed to agree.
{
    printf '# Mule App Spec — %s\n\n' "$PROJECT_NAME"

    SUMMARY=$(jq -r '.summary // ""' "$SIDECAR_JSON")
    if [ -n "$SUMMARY" ]; then
        printf '## What it does\n\n%s\n\n' "$SUMMARY"
    fi

    printf '## Trigger\n\n'
    jq -r '
      .trigger as $t |
      if ($t.type // "http-listener") == "http-listener" then
        "- HTTP listener at `" + ($t.method // "POST") + " " + ($t.path // "/") + "`"
      else
        "- " + ($t.type // "<unknown>")
      end
    ' "$INPUTS"
    printf '\n'

    printf '## Source\n\n'
    jq -r '
      .source // empty |
      "- Connector: `" + (.connectorId // "<unset>") + "` (namespace: `" + ((.namespace.prefix // .namespace) // "<unset>") + "`)\n" +
      "- Operation: `" + (.operation // "<unset>") + "`\n" +
      (if .params and (.params | length > 0) then
        "- Parameters:\n" + (
          .params | to_entries
          | map("  - **" + .key + "**: `" + (.value | tostring) + "`") | join("\n")
        )
       else "" end)
    ' "$SIDECAR_JSON"
    printf '\n\n'

    printf '## Target\n\n'
    jq -r '
      .target // empty |
      "- Connector: `" + (.connectorId // "<unset>") + "` (namespace: `" + ((.namespace.prefix // .namespace) // "<unset>") + "`)\n" +
      "- Operation: `" + (.operation // "<unset>") + "`\n" +
      (if .params and (.params | length > 0) then
        "- Parameters:\n" + (
          .params | to_entries
          | map("  - **" + .key + "**: " + (.value | tostring | "\n    ```\n    " + . + "\n    ```")) | join("\n")
        )
       else "" end)
    ' "$SIDECAR_JSON"
    printf '\n\n'

    printf '## Configuration the user must fill in (after Open in ACB)\n\n'
    jq -r '
      def provider_keys($block):
        ($block.connectionProvider.attributes // [])
        | map(select(.required == true))
        | map(.attributeName);

      [
        ( provider_keys(.connectors.source)  | map(((.connectors.source.connectorId  // "source")  + "." + .)) ),
        ( provider_keys(.connectors.target)  | map(((.connectors.target.connectorId  // "target")  + "." + .)) ),
        ( provider_keys(.connectors.trigger) | map(((.connectors.trigger.connectorId // "trigger") + "." + .)) )
      ]
      | add
      | unique
      | map("- `" + . + "`")
      | .[]
    ' "$SIDECAR_JSON"
    printf '\n'

    printf '## Files the scaffolder will create\n\n'
    cat <<EOF
\`\`\`
<project-dir>/
├── project-artifact.json
├── README.md
├── src/
│   └── main/
│       ├── mule/
│       │   └── ${PROJECT_NAME}.xml
│       └── resources/
│           └── config.yaml
└── yaml/
    ├── config.yaml
    └── ${PROJECT_NAME}-flow.yaml
\`\`\`

EOF
} > "$SIDECAR_MD"

echo "✅ Spec written"
echo "   Markdown: $SIDECAR_MD"
echo "   Sidecar:  $SIDECAR_JSON"
echo ""
echo "--- $SIDECAR_MD ---"
cat "$SIDECAR_MD"
