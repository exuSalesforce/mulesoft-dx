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

    # Pass big descriptors via --slurpfile (file path) instead of --argjson
    # — descriptor JSON for connectors like Twilio is several hundred KB
    # and overflows the OS exec arg limit.
    if [ ! -f "$descriptor_file" ]; then
        descriptor_file="/dev/null"
        if [ -n "$connector_id" ]; then
            echo "⚠️  No descriptor at $METADATA_DIR/${nickname}.json — run describe_connector.sh first." >&2
        fi
    fi
    if [ ! -f "$op_file" ]; then
        op_file="/dev/null"
        if [ -n "$operation" ]; then
            echo "⚠️  No operation schema at $METADATA_DIR/${nickname}.${operation}.json — run describe_operation.sh first." >&2
        fi
    fi

    # --slurpfile reads the file into an array (one element per top-level
    # JSON document); we always have exactly one document, so the helper
    # accesses it with [0]. /dev/null produces an empty array, which the
    # filter coalesces to null.
    jq -n \
        --argjson role_obj "$role_obj" \
        --slurpfile descriptorArr "$descriptor_file" \
        --slurpfile opSchemaArr   "$op_file" \
        '
        # Helpers walk the descriptor object directly via the `.` cursor
        # so the same definition works for any connector.
        def find_config:
            (.extensionModel.configurations // []) as $configs
            | (
                ($configs[] | select(.name == ($role_obj.config.name // ""))),
                $configs[0]
              ) // null;

        def find_provider($cfg):
            ($cfg.connectionProviders // []) as $providers
            | (
                ($providers[] | select(.name == ($role_obj.config.provider // ""))),
                $providers[0]
              ) // null;

        def find_config_dsl($cfgName):
            (.dsl.configurations[$cfgName] // null);

        # --slurpfile yields a one-element array (or empty for /dev/null).
        ($descriptorArr | first // null) as $d
        | ($opSchemaArr  | first // null) as $op_schema
        | ($d | if . == null then null else find_config end) as $cfg
        | (if $cfg == null then null else ($d | find_provider($cfg)) end) as $provider
        | (if $cfg == null then null else ($d | find_config_dsl($cfg.name)) end) as $cfgDsl
        | {
            connectorId: ($role_obj.connectorId // null),
            nickname:    ($role_obj.nickname    // $role_obj.connectorId // null),
            namespace:   (
                if $d == null then null
                else {
                    prefix:         ($d.extensionModel.xmlDsl.prefix // null),
                    namespace:      ($d.extensionModel.xmlDsl.namespace // null),
                    schemaLocation: ($d.extensionModel.xmlDsl.schemaLocation // null),
                    xsdFileName:    ($d.extensionModel.xmlDsl.xsdFileName // null)
                }
                end
            ),
            config: (
                if $cfg == null then ($role_obj.config // null)
                else {
                    name:        ($role_obj.config.name // $cfg.name),
                    elementName: ($cfgDsl.elementName // $cfg.name),
                    provider:    (if $provider == null then null else $provider.name end)
                }
                end
            ),
            operation:   ($role_obj.operation // null),
            params:      ($role_obj.params    // {}),
            connectionProvider: (
                if $provider == null then null
                else {
                    name:        $provider.name,
                    elementName: ($provider.name + "-connection"),
                    parameters: (
                        [
                          ($provider.parameterGroupModels // [])[]
                          | (.parameterModels // [])[]
                          | {
                              name:         .name,
                              required:     (.required // false),
                              type:         (.type.type // null),
                              defaultValue: (.defaultValue // null),
                              description:  (.description // "")
                            }
                        ]
                    )
                }
                end
            ),
            operationSchema: $op_schema,
            errorTypes:      (if $d == null then [] else ($d.extensionModel.errors // [] | map(.type)) end)
          }
        '
}

# Resolved role blocks can each be hundreds of KB once the operation's
# parameterModels are inlined, so we stage them to disk and pass paths
# to the final consolidating jq via --slurpfile (avoids "Argument list
# too long" at the OS level).
TMP_RESOLVED="${TMPDIR:-/tmp}/poc-resolved.$$"
mkdir -p "$TMP_RESOLVED"
trap 'rm -rf "$TMP_RESOLVED"' EXIT

resolve_role source  > "$TMP_RESOLVED/source.json"
resolve_role target  > "$TMP_RESOLVED/target.json"
resolve_role trigger > "$TMP_RESOLVED/trigger.json"

SIDECAR_JSON="$SPEC_DIR/${PROJECT_NAME}.json"
SIDECAR_MD="$SPEC_DIR/${PROJECT_NAME}.md"

jq -n \
    --slurpfile inputs  "$INPUTS" \
    --slurpfile source  "$TMP_RESOLVED/source.json" \
    --slurpfile target  "$TMP_RESOLVED/target.json" \
    --slurpfile trigger "$TMP_RESOLVED/trigger.json" \
    '$inputs[0] + {
        connectors: {
            source:  ($source[0]  // null),
            target:  ($target[0]  // null),
            trigger: ($trigger[0] // null)
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
      elif $t.type == "scheduler" then
        "- Scheduler (fixed-frequency): every "
          + (($t.frequency // 5) | tostring) + " "
          + (($t.timeUnit // "MINUTES") | ascii_downcase)
          + (if ($t.startDelay // 0) > 0
             then ", start delay " + (($t.startDelay // 0) | tostring) + " " + (($t.timeUnit // "MINUTES") | ascii_downcase)
             else ""
             end)
      else
        "- " + ($t.type // "<unknown>")
      end
    ' "$INPUTS"
    printf '\n'

    printf '## Source\n\n'
    jq -r '
      .connectors.source // empty |
      "- Connector: `" + (.connectorId // "<unset>") + "` (namespace: `" + (.namespace.prefix // "<unset>") + "`)\n" +
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
      .connectors.target // empty |
      "- Connector: `" + (.connectorId // "<unset>") + "` (namespace: `" + (.namespace.prefix // "<unset>") + "`)\n" +
      "- Operation: `" + (.operation // "<unset>") + "`\n" +
      (if .params and (.params | length > 0) then
        "- Parameters:\n" + (
          .params | to_entries
          | map("  - **" + .key + "**: `" + (.value | tostring) + "`") | join("\n")
        )
       else "" end)
    ' "$SIDECAR_JSON"
    printf '\n\n'

    printf '## Configuration the user must fill in (after Open in ACB)\n\n'
    jq -r '
      def provider_keys($block; $prefix):
        ($block.connectionProvider.parameters // [])
        | map(select(.required == true))
        | map($prefix + "." + .name);

      def trigger_keys:
        if (.trigger.type // "http-listener") == "scheduler" then
          ["app.limit", "app.phoneNumber"]
        else
          ["http.host", "http.port"]
        end;

      .connectors.source as $src
      | .connectors.target as $tgt
      | [
          provider_keys($src; ($src.namespace.prefix // $src.connectorId // "source")),
          provider_keys($tgt; ($tgt.namespace.prefix // $tgt.connectorId // "target")),
          trigger_keys
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
