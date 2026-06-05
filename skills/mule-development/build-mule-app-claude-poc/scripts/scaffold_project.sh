#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 9 helper — read the approved spec sidecar (produced by write_spec.sh)
# and scaffold the project files.
#
# Output tree (no Maven, no Java, no mule-artifact.json):
#   <POC_PROJECT_DIR>/
#   ├── project-artifact.json     # connector manifest (source/target/trigger metadata)
#   ├── README.md
#   ├── src/main/mule/<project>.xml
#   ├── src/main/resources/config.yaml
#   └── yaml/
#       ├── config.yaml
#       └── <project>-flow.yaml
#
# All XML / YAML output is derived from the spec sidecar. Connector
# element names, attribute names, and namespace URIs come straight from
# the Remote Design Service descriptors (extensionModel + dsl). The
# scaffolder never invents an attribute name or assumes a wrapper child
# element — what the descriptor says, the XML emits.
#
# Trigger handling has two templates (chosen from spec.trigger.type):
#   - "http-listener" → emits <http:listener-config> + <http:listener>,
#                       reads payload.* into vars
#   - "scheduler"     → emits <scheduler><scheduling-strategy>...,
#                       reads p('app.*') into vars
#
# Usage:
#   scripts/scaffold_project.sh <spec-sidecar.json>
#
# Output dir is ${POC_PROJECT_DIR} when set; otherwise
# ~/projects/mule-poc-output/<projectName>.
#
# Exit code:
#   0  success
#   1  spec missing required fields, project dir already non-empty, etc.
set -euo pipefail

usage() {
    echo "Usage: $0 <spec-sidecar.json>" >&2
    echo "  e.g. $0 tmp/spec/salesforce-accounts-to-twilio.json" >&2
}

SPEC="${1:-}"
if [ -z "$SPEC" ]; then
    usage
    exit 1
fi
if [ ! -f "$SPEC" ]; then
    echo "❌ spec sidecar not found: $SPEC" >&2
    exit 1
fi

PROJECT_NAME=$(jq -r '.projectName // empty' "$SPEC")
if [ -z "$PROJECT_NAME" ]; then
    echo "❌ spec sidecar missing required field: projectName" >&2
    exit 1
fi

PROJECT_DIR="${POC_PROJECT_DIR:-${HOME}/projects/mule-poc-output/$PROJECT_NAME}"

mkdir -p "$(dirname "$PROJECT_DIR")"
if [ -e "$PROJECT_DIR" ] && [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
    echo "❌ project directory already exists and is not empty: $PROJECT_DIR" >&2
    echo "   Move it aside or remove it before re-scaffolding." >&2
    exit 1
fi

mkdir -p "$PROJECT_DIR/src/main/mule" \
         "$PROJECT_DIR/src/main/resources" \
         "$PROJECT_DIR/yaml"

METADATA_DIR="${CONNECTOR_METADATA_DIR:-tmp/connector-metadata}"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# Pull a value from the spec sidecar.
spec() { jq -r "$1" "$SPEC"; }

# Read a slice from the spec into a variable.
SOURCE_PREFIX=$(spec '.connectors.source.namespace.prefix // ""')
SOURCE_NS_URI=$(spec '.connectors.source.namespace.namespace // ""')
SOURCE_NS_XSD=$(spec '.connectors.source.namespace.schemaLocation // ""')
SOURCE_CONFIG_NAME=$(spec '.connectors.source.config.name // ""')
SOURCE_CONFIG_ELEMENT=$(spec '.connectors.source.config.elementName // ""')
SOURCE_OPERATION=$(spec '.connectors.source.operation // ""')

TARGET_PREFIX=$(spec '.connectors.target.namespace.prefix // ""')
TARGET_NS_URI=$(spec '.connectors.target.namespace.namespace // ""')
TARGET_NS_XSD=$(spec '.connectors.target.namespace.schemaLocation // ""')
TARGET_CONFIG_NAME=$(spec '.connectors.target.config.name // ""')
TARGET_CONFIG_ELEMENT=$(spec '.connectors.target.config.elementName // ""')
TARGET_OPERATION=$(spec '.connectors.target.operation // ""')

TRIGGER_TYPE=$(spec '.trigger.type // "http-listener"')

# emit_op_attrs <role>
#   For the role's operationSchema.attributes[], emit one XML attribute
#   per parameter where:
#     - the dsl says it can be an attribute (asAttribute == true)
#     - AND either the spec provides a value via .params, OR the parameter is required
#   Required params with no user value get a ${prefix.name} placeholder.
#   The first attribute is always config-ref (handled by caller).
emit_op_attrs() {
    local role="$1"
    jq -r --arg role "$role" '
        .connectors[$role] as $r
        | $r.namespace.prefix as $prefix
        | ($r.params // {}) as $p
        | ($r.operationSchema.attributes // [])
        | map(select(.name != "config-ref" and .asAttribute == true))
        | map(
            . as $attr
            | $p[$attr.name] as $userVal
            | if ($userVal != null and ($userVal | tostring) != "") then
                "                " + $attr.name + "=\"" + ($userVal | tostring | gsub("\""; "&quot;")) + "\""
              elif $attr.required then
                "                " + $attr.name + "=\"${" + $prefix + "." + $attr.name + "}\""
              else empty
              end
          )
        | .[]
    ' "$SPEC"
}

# emit_provider_attrs <role>
#   For the role's connectionProvider.parameters[], emit ${prefix.name}
#   placeholders for every required parameter. Returns empty when the
#   connector has no connectionProvider (e.g. salesforce on go-runtime).
emit_provider_attrs() {
    local role="$1"
    jq -r --arg role "$role" '
        .connectors[$role] as $r
        | if $r.connectionProvider == null then empty
          else
            $r.namespace.prefix as $prefix
            | ($r.connectionProvider.parameters // [])
            | map(select(.required == true))
            | map("            " + .name + "=\"${" + $prefix + "." + .name + "}\"")
            | .[]
          end
    ' "$SPEC"
}

SOURCE_OP_ATTRS=$(emit_op_attrs source)
TARGET_OP_ATTRS=$(emit_op_attrs target)
SOURCE_PROV_ATTRS=$(emit_provider_attrs source)
TARGET_PROV_ATTRS=$(emit_provider_attrs target)

# Element name for the operation (dsl.elementName, falls back to op name)
SOURCE_OP_ELEMENT=$(spec '.connectors.source.operationSchema.elementName // .connectors.source.operation // ""')
TARGET_OP_ELEMENT=$(spec '.connectors.target.operationSchema.elementName // .connectors.target.operation // ""')

# Connection provider element name (e.g. "basic-connection",
# "account-sid-auth-token-connection")
SOURCE_PROV_ELEMENT=$(spec '.connectors.source.connectionProvider.elementName // ""')
TARGET_PROV_ELEMENT=$(spec '.connectors.target.connectionProvider.elementName // ""')

# ----------------------------------------------------------------------
# 1. project-artifact.json — connector manifest
# ----------------------------------------------------------------------
ARTIFACT="$PROJECT_DIR/project-artifact.json"
jq --arg projectName "$PROJECT_NAME" '
{
  projectName: $projectName,
  trigger:    .trigger,
  connectors: .connectors
}
' "$SPEC" > "$ARTIFACT"
echo "✅ wrote $ARTIFACT"

# ----------------------------------------------------------------------
# 2. config.yaml files — placeholders for required attrs
# ----------------------------------------------------------------------
RESOURCES_YAML="$PROJECT_DIR/src/main/resources/config.yaml"
GO_YAML="$PROJECT_DIR/yaml/config.yaml"

# Build {ns, attr} tuples for every required parameter on the chosen
# connection provider of source/target. When a connector has no
# provider (salesforce go-runtime) the loop yields nothing for it.
PLACEHOLDERS=$(jq -r '
  def kv(role):
    .connectors[role] as $r
    | if $r.connectionProvider == null then empty
      else
        ($r.namespace.prefix // role) as $ns
        | ($r.connectionProvider.parameters // [])
        | map(select(.required == true))
        | map("\($ns)\t\(.name)")[]
      end;
  kv("source"), kv("target")
' "$SPEC")

# resources/config.yaml — env-var placeholders for ACB
{
    declare -A SEEN_NS=()
    if [ -n "$PLACEHOLDERS" ]; then
        while IFS=$'\t' read -r ns attr; do
            [ -z "$ns" ] && continue
            if [ -z "${SEEN_NS[$ns]:-}" ]; then
                printf '%s:\n' "$ns"
                SEEN_NS[$ns]=1
            fi
            UPPER=$(printf '%s_%s' "$ns" "$attr" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
            printf '  %s: "${%s}"\n' "$attr" "$UPPER"
        done <<<"$PLACEHOLDERS"
    fi

    if [ "$TRIGGER_TYPE" = "scheduler" ]; then
        cat <<'EOF'

app:
  limit: "${APP_LIMIT}"
  phoneNumber: "${APP_PHONE_NUMBER}"
EOF
    else
        cat <<'EOF'

http:
  host: "${HTTP_HOST:-0.0.0.0}"
  port: "${HTTP_PORT:-8081}"
EOF
    fi
} > "$RESOURCES_YAML"
echo "✅ wrote $RESOURCES_YAML"

# yaml/config.yaml — Go-runtime style ${dot.notation}
{
    declare -A SEEN_NS2=()
    if [ -n "$PLACEHOLDERS" ]; then
        while IFS=$'\t' read -r ns attr; do
            [ -z "$ns" ] && continue
            if [ -z "${SEEN_NS2[$ns]:-}" ]; then
                printf '%s:\n' "$ns"
                SEEN_NS2[$ns]=1
            fi
            printf '    %s: ${%s.%s}\n' "$attr" "$ns" "$attr"
        done <<<"$PLACEHOLDERS"
    fi

    if [ "$TRIGGER_TYPE" = "scheduler" ]; then
        cat <<'EOF'

app:
    limit: ${app.limit}
    phoneNumber: ${app.phoneNumber}
EOF
    else
        cat <<'EOF'

http:
    host: ${http.host}
    port: ${http.port}
EOF
    fi
} > "$GO_YAML"
echo "✅ wrote $GO_YAML"

# ----------------------------------------------------------------------
# 3. src/main/mule/<project>.xml — the Mule flow
# ----------------------------------------------------------------------
FLOW_XML="$PROJECT_DIR/src/main/mule/${PROJECT_NAME}.xml"

# XML-escape the summary for the flow's doc:description.
SUMMARY_RAW=$(spec '.summary // "Auto-generated Mule flow"')
SUMMARY_ESC=$(printf '%s' "$SUMMARY_RAW" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')

# Trigger snippets ---------------------------------------------------
case "$TRIGGER_TYPE" in
    scheduler)
        FREQUENCY=$(spec '.trigger.frequency // 5')
        TIME_UNIT=$(spec '.trigger.timeUnit // "MINUTES"')
        START_DELAY=$(spec '.trigger.startDelay // 0')
        TRIGGER_GLOBAL_CONFIG=""
        TRIGGER_ELEMENT="<scheduler doc:name=\"Scheduler\"
            doc:description=\"Fires every ${FREQUENCY} ${TIME_UNIT} (start delay ${START_DELAY})\">
            <scheduling-strategy>
                <fixed-frequency frequency=\"${FREQUENCY}\" timeUnit=\"${TIME_UNIT}\" startDelay=\"${START_DELAY}\"/>
            </scheduling-strategy>
        </scheduler>"
        SET_VARS="<set-variable variableName=\"limit\" value=\"#[p('app.limit')]\"
            doc:name=\"Set Limit\"
            doc:description=\"Reads record limit from app.limit config\"/>

        <set-variable variableName=\"phoneNumber\" value=\"#[p('app.phoneNumber')]\"
            doc:name=\"Set Phone Number\"
            doc:description=\"Reads target phone number from app.phoneNumber config\"/>"
        FINAL_RESPONSE_TRANSFORM=""
        ;;
    http-listener|*)
        TRIGGER_METHOD=$(spec '.trigger.method // "POST"')
        TRIGGER_PATH=$(spec '.trigger.path // ("/ops/" + .projectName)')
        TRIGGER_GLOBAL_CONFIG="<http:listener-config name=\"httpListenerConfig\"
        doc:name=\"HTTP Listener Config\"
        doc:description=\"HTTP listener configuration for inbound requests\">
        <http:listener-connection host=\"\${http.host}\" port=\"\${http.port}\"/>
    </http:listener-config>"
        TRIGGER_ELEMENT="<http:listener config-ref=\"httpListenerConfig\" path=\"${TRIGGER_PATH}\" allowedMethods=\"${TRIGGER_METHOD}\"
            doc:name=\"HTTP ${TRIGGER_METHOD} ${TRIGGER_PATH}\"
            doc:description=\"Receives ${TRIGGER_METHOD} requests from the caller\"/>"
        SET_VARS="<set-variable variableName=\"limit\" value=\"#[payload.limit]\"
            doc:name=\"Set Limit\"
            doc:description=\"Extracts the record limit from the request body\"/>

        <set-variable variableName=\"phoneNumber\" value=\"#[payload.phoneNumber]\"
            doc:name=\"Set Phone Number\"
            doc:description=\"Extracts the target phone number from the request body\"/>"
        FINAL_RESPONSE_TRANSFORM="<ee:transform
            doc:name=\"Build Response\"
            doc:description=\"Returns recordsNotified, phoneNumber and target response\">
            <ee:message>
                <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{
    recordsNotified: sizeOf(vars.records default []),
    phoneNumber:     vars.phoneNumber,
    targetResponse:  vars.targetResp
}]]></ee:set-payload>
            </ee:message>
        </ee:transform>"
        ;;
esac

# Connection-provider sub-elements (omitted entirely when the
# connector has no provider on the Go runtime — like salesforce).
SOURCE_CONN_ELEMENT_XML=""
if [ -n "$SOURCE_PROV_ELEMENT" ]; then
    SOURCE_CONN_ELEMENT_XML="<${SOURCE_PREFIX}:${SOURCE_PROV_ELEMENT}
${SOURCE_PROV_ATTRS}/>"
fi
TARGET_CONN_ELEMENT_XML=""
if [ -n "$TARGET_PROV_ELEMENT" ]; then
    TARGET_CONN_ELEMENT_XML="<${TARGET_PREFIX}:${TARGET_PROV_ELEMENT}
${TARGET_PROV_ATTRS}/>"
fi

cat > "$FLOW_XML" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<mule xmlns="http://www.mulesoft.org/schema/mule/core"
      xmlns:http="http://www.mulesoft.org/schema/mule/http"
      xmlns:${SOURCE_PREFIX}="${SOURCE_NS_URI}"
      xmlns:${TARGET_PREFIX}="${TARGET_NS_URI}"
      xmlns:ee="http://www.mulesoft.org/schema/mule/ee/core"
      xmlns:doc="http://www.mulesoft.org/schema/mule/documentation"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="
        http://www.mulesoft.org/schema/mule/core http://www.mulesoft.org/schema/mule/core/current/mule.xsd
        http://www.mulesoft.org/schema/mule/http http://www.mulesoft.org/schema/mule/http/current/mule-http.xsd
        ${SOURCE_NS_URI} ${SOURCE_NS_XSD}
        ${TARGET_NS_URI} ${TARGET_NS_XSD}
        http://www.mulesoft.org/schema/mule/ee/core http://www.mulesoft.org/schema/mule/ee/core/current/mule-ee.xsd">

    <configuration-properties file="config.yaml"
        doc:name="Configuration Properties"
        doc:description="Loads externalized configuration from config.yaml"/>

    ${TRIGGER_GLOBAL_CONFIG}

    <${SOURCE_PREFIX}:${SOURCE_CONFIG_ELEMENT} name="${SOURCE_CONFIG_NAME}"
        doc:name="${SOURCE_PREFIX} Config"
        doc:description="${SOURCE_PREFIX} connection (auto-generated from RDS metadata)">
        ${SOURCE_CONN_ELEMENT_XML}
    </${SOURCE_PREFIX}:${SOURCE_CONFIG_ELEMENT}>

    <${TARGET_PREFIX}:${TARGET_CONFIG_ELEMENT} name="${TARGET_CONFIG_NAME}"
        doc:name="${TARGET_PREFIX} Config"
        doc:description="${TARGET_PREFIX} connection (auto-generated from RDS metadata)">
        ${TARGET_CONN_ELEMENT_XML}
    </${TARGET_PREFIX}:${TARGET_CONFIG_ELEMENT}>

    <flow name="${PROJECT_NAME}"
        doc:name="${PROJECT_NAME}"
        doc:description="${SUMMARY_ESC}">

        ${TRIGGER_ELEMENT}

        ${SET_VARS}

        <${SOURCE_PREFIX}:${SOURCE_OP_ELEMENT} config-ref="${SOURCE_CONFIG_NAME}"
            doc:name="Query ${SOURCE_PREFIX}"
            doc:description="Calls ${SOURCE_PREFIX}:${SOURCE_OP_ELEMENT} via RDS-described attributes"
            target="records"
${SOURCE_OP_ATTRS}/>

        <logger level="INFO"
            message="#[output text/plain --- 'Queried ' ++ sizeOf(vars.records default []) ++ ' records']"
            doc:name="Log Query Count"
            doc:description="Logs the number of records returned by ${SOURCE_PREFIX}:${SOURCE_OP_ELEMENT}"/>

        <${TARGET_PREFIX}:${TARGET_OP_ELEMENT} config-ref="${TARGET_CONFIG_NAME}"
            doc:name="Send via ${TARGET_PREFIX}"
            doc:description="Calls ${TARGET_PREFIX}:${TARGET_OP_ELEMENT} via RDS-described attributes"
            target="targetResp"
${TARGET_OP_ATTRS}/>

        <logger level="INFO"
            message="#[output text/plain --- 'Sent via ${TARGET_PREFIX}: ' ++ (vars.targetResp default 'no response')]"
            doc:name="Log ${TARGET_PREFIX} Response"
            doc:description="Logs the response returned by ${TARGET_PREFIX}:${TARGET_OP_ELEMENT}"/>

        ${FINAL_RESPONSE_TRANSFORM}

        <error-handler>
            <on-error-propagate type="ANY"
                doc:name="On Error"
                doc:description="Logs the error and propagates it to the caller">
                <logger level="ERROR"
                    message="#[output text/plain --- 'Flow error: ' ++ (error.description default 'no description')]"
                    doc:name="Log Error Detail"
                    doc:description="Logs the error description for diagnostics"/>
            </on-error-propagate>
        </error-handler>

    </flow>
</mule>
XMLEOF
echo "✅ wrote $FLOW_XML"

# ----------------------------------------------------------------------
# 4. yaml/<project>-flow.yaml — minimal Go-runtime YAML representation
# ----------------------------------------------------------------------
GO_FLOW_YAML="$PROJECT_DIR/yaml/${PROJECT_NAME}-flow.yaml"
{
    printf 'flow:\n'
    printf '    name: %s\n' "$PROJECT_NAME"
    printf '    trigger:\n'
    if [ "$TRIGGER_TYPE" = "scheduler" ]; then
        printf '        scheduler:\n'
        printf '            frequency: %s\n' "$(spec '.trigger.frequency // 5')"
        printf '            timeUnit: %s\n'  "$(spec '.trigger.timeUnit // "MINUTES"')"
        printf '            startDelay: %s\n' "$(spec '.trigger.startDelay // 0')"
    else
        printf '        http-listener:\n'
        printf '            method: %s\n' "$(spec '.trigger.method // "POST"')"
        printf '            path: %s\n'   "$(spec '.trigger.path // ("/ops/" + .projectName)')"
    fi
    printf '    steps:\n'
    printf '        - source-operation:\n'
    printf '            connector: %s\n' "$SOURCE_PREFIX"
    printf '            operation: %s\n' "$SOURCE_OPERATION"
    printf '            target: vars.records\n'
    printf '        - target-operation:\n'
    printf '            connector: %s\n' "$TARGET_PREFIX"
    printf '            operation: %s\n' "$TARGET_OPERATION"
    printf '            target: vars.targetResp\n'
} > "$GO_FLOW_YAML"
echo "✅ wrote $GO_FLOW_YAML"

# ----------------------------------------------------------------------
# 5. README.md — short developer guide
# ----------------------------------------------------------------------
README="$PROJECT_DIR/README.md"
SUMMARY=$(spec '.summary // "Mule application generated by build-mule-app-claude-poc."')
{
    printf '# %s\n\n%s\n\n' "$PROJECT_NAME" "$SUMMARY"
    printf '## Run on the Go runtime\n\n'
    printf '```bash\ngo-runtime --xml-flows ./src/main/mule \\\n'
    printf '           --xml-properties ./src/main/resources/config.yaml\n```\n\n'
    if [ "$TRIGGER_TYPE" = "http-listener" ]; then
        TRIGGER_METHOD=$(spec '.trigger.method // "POST"')
        TRIGGER_PATH=$(spec '.trigger.path // ("/ops/" + .projectName)')
        printf '## Test\n\n```bash\n'
        printf 'curl -X %s http://localhost:8081%s \\\n' "$TRIGGER_METHOD" "$TRIGGER_PATH"
        printf '  -H "Content-Type: application/json" \\\n'
        printf '  -d %s\n```\n\n' "'{\"limit\": 5, \"phoneNumber\": \"+15105551212\"}'"
    else
        printf '## Schedule\n\nThe scheduler fires every %s %s. Set `app.limit` and `app.phoneNumber` in `src/main/resources/config.yaml` before starting the runtime.\n\n' "$(spec '.trigger.frequency // 5')" "$(spec '.trigger.timeUnit // "MINUTES"')"
    fi
    printf '## Configuration\n\nFill in the placeholders in `src/main/resources/config.yaml` (or set them via environment variables) before running.\n'
} > "$README"
echo "✅ wrote $README"

# ----------------------------------------------------------------------
# 6. ACB link sidecar
# ----------------------------------------------------------------------
ACB_LINK_FILE="${SPEC_DIR:-tmp/spec}/${PROJECT_NAME}.acb-link.txt"
ABS_PROJECT=$(cd "$PROJECT_DIR" && pwd)
mkdir -p "$(dirname "$ACB_LINK_FILE")"
printf 'acb://open?path=%s\n' "$ABS_PROJECT" > "$ACB_LINK_FILE"
echo "✅ wrote $ACB_LINK_FILE"

# ----------------------------------------------------------------------
# 7. Validate XML against the connector XSDs (warn-only)
# ----------------------------------------------------------------------
if command -v xmllint >/dev/null 2>&1; then
    SOURCE_NICK=$(spec '.connectors.source.nickname // ""')
    TARGET_NICK=$(spec '.connectors.target.nickname // ""')
    SOURCE_XSD="$METADATA_DIR/${SOURCE_NICK}.xsd"
    TARGET_XSD="$METADATA_DIR/${TARGET_NICK}.xsd"
    XSD_FILES=()
    [ -f "$SOURCE_XSD" ] && XSD_FILES+=("$SOURCE_XSD")
    [ -f "$TARGET_XSD" ] && [ "$TARGET_XSD" != "$SOURCE_XSD" ] && XSD_FILES+=("$TARGET_XSD")

    if [ ${#XSD_FILES[@]} -gt 0 ]; then
        # xmllint --schema validates against ONE schema at a time and
        # complains about elements outside that schema. We only run a
        # well-formedness check (--noout) here — a true cross-schema
        # validation would need an aggregate XSD which is out of scope
        # for this POC.
        if xmllint --noout "$FLOW_XML" 2>/dev/null; then
            echo "✅ XML is well-formed"
        else
            echo "⚠️  XML failed well-formedness check — see xmllint output below" >&2
            xmllint --noout "$FLOW_XML" || true
        fi
    fi
else
    echo "ℹ️  xmllint not installed — skipping XML well-formedness check"
fi

echo ""
echo "🎉 Project scaffolded at: $PROJECT_DIR"
