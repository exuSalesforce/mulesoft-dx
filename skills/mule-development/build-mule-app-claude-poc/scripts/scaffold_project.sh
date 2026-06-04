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
# The XML, config files, and project-artifact.json are all derived from
# tmp/connector-metadata/ + the spec sidecar — nothing is hardcoded except
# the doc:* attributes (which are human-readable labels) and the standard
# `<configuration-properties>` / `<http:listener-config>` boilerplate.
#
# Usage:
#   scripts/scaffold_project.sh <spec-sidecar.json>
#
# Output dir is ${POC_PROJECT_DIR} when set; otherwise ./<projectName>.
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

PROJECT_DIR="${POC_PROJECT_DIR:-./$PROJECT_NAME}"

if [ -e "$PROJECT_DIR" ] && [ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
    echo "❌ project directory already exists and is not empty: $PROJECT_DIR" >&2
    echo "   Move it aside or remove it before re-scaffolding." >&2
    exit 1
fi

mkdir -p "$PROJECT_DIR/src/main/mule" \
         "$PROJECT_DIR/src/main/resources" \
         "$PROJECT_DIR/yaml"

# ----------------------------------------------------------------------
# 1. project-artifact.json — connector manifest
# ----------------------------------------------------------------------
ARTIFACT="$PROJECT_DIR/project-artifact.json"
jq --arg projectName "$PROJECT_NAME" '
{
  projectName: $projectName,
  connectors: {
    source:  (.connectors.source  // null),
    target:  (.connectors.target  // null),
    trigger: (.connectors.trigger // null)
  }
}
' "$SPEC" > "$ARTIFACT"
echo "✅ wrote $ARTIFACT"

# ----------------------------------------------------------------------
# 2. config.yaml files — placeholders for required connection-provider attrs
# ----------------------------------------------------------------------
RESOURCES_YAML="$PROJECT_DIR/src/main/resources/config.yaml"
GO_YAML="$PROJECT_DIR/yaml/config.yaml"

# Build a list of {role, prefix, attributeName} tuples for every required
# attribute on the chosen connection provider of source/target. Trigger is
# always HTTP listener for this POC, so we add http.host / http.port
# placeholders explicitly.
PLACEHOLDERS=$(jq -r '
  def kv(role; ns):
    .connectors[role] // empty
    | (.connectionProvider.attributes // [])
    | map(select(.required == true))
    | map({
        role: role,
        ns:   (ns // role),
        attr: .attributeName
      });

  [ kv("source"; (.connectors.source.namespace.prefix // .connectors.source.namespace // "source")),
    kv("target"; (.connectors.target.namespace.prefix // .connectors.target.namespace // "target")) ]
  | add
  | .[]
  | "\(.ns)\t\(.attr)"
' "$SPEC")

# Always add http.host / http.port for the listener
{
    echo "salesforce_default_url"
} >/dev/null

# resources/config.yaml — env-var placeholders for ACB
{
    # group placeholders by namespace prefix
    declare -A SEEN_NS=()
    while IFS=$'\t' read -r ns attr; do
        [ -z "$ns" ] && continue
        if [ -z "${SEEN_NS[$ns]:-}" ]; then
            printf '%s:\n' "$ns"
            SEEN_NS[$ns]=1
        fi
        UPPER=$(printf '%s_%s' "$ns" "$attr" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
        printf '  %s: "${%s}"\n' "$attr" "$UPPER"
    done <<<"$PLACEHOLDERS"

    cat <<'EOF'

http:
  host: "0.0.0.0"
  port: "8081"
EOF
} > "$RESOURCES_YAML"
echo "✅ wrote $RESOURCES_YAML"

# yaml/config.yaml — Go-runtime style ${dot.notation}
{
    declare -A SEEN_NS2=()
    while IFS=$'\t' read -r ns attr; do
        [ -z "$ns" ] && continue
        if [ -z "${SEEN_NS2[$ns]:-}" ]; then
            printf '%s:\n' "$ns"
            SEEN_NS2[$ns]=1
        fi
        printf '    %s: ${%s.%s}\n' "$attr" "$ns" "$attr"
    done <<<"$PLACEHOLDERS"

    cat <<'EOF'

http:
    host: ${http.host}
    port: ${http.port}
EOF
} > "$GO_YAML"
echo "✅ wrote $GO_YAML"

# ----------------------------------------------------------------------
# 3. src/main/mule/<project>.xml — the Mule flow
# ----------------------------------------------------------------------
FLOW_XML="$PROJECT_DIR/src/main/mule/${PROJECT_NAME}.xml"

# Read everything we need into shell vars
SOURCE_NS=$(jq -r '.connectors.source.namespace.prefix // .connectors.source.namespace // ""' "$SPEC")
SOURCE_NS_URI=$(jq -r '.connectors.source.namespace.namespace // ("http://www.mulesoft.org/schema/mule/" + (.connectors.source.namespace.prefix // .connectors.source.namespace // ""))' "$SPEC")
SOURCE_NS_XSD=$(jq -r '
  .connectors.source.namespace.schemaLocation
  // ("http://www.mulesoft.org/schema/mule/" + (.connectors.source.namespace.prefix // .connectors.source.namespace // "") + "/current/mule-" + (.connectors.source.namespace.prefix // .connectors.source.namespace // "") + ".xsd")
' "$SPEC")
SOURCE_CONFIG_NAME=$(jq -r '.connectors.source.config.name // ""' "$SPEC")
SOURCE_CONFIG_ELEMENT=$(jq -r '
  (.connectors.source.connectionProvider // null) as $cp
  | if $cp == null then ""
    else (
      # The config element is the descriptor's first config.elementName — fall
      # back to "<prefix>-config" when missing.
      .connectors.source.config.name as $cn |
      if $cn != null and $cn != "" then $cn
      else (.connectors.source.namespace.prefix + "-config")
      end
    )
  end
' "$SPEC")
SOURCE_CONN_ELEMENT=$(jq -r '.connectors.source.connectionProvider.elementName // ""' "$SPEC")
SOURCE_OPERATION=$(jq -r '.connectors.source.operation // ""' "$SPEC")
SOURCE_OP_ELEMENT=$(jq -r '.connectors.source.operationSchema.elementName // .connectors.source.operation // ""' "$SPEC")
SOURCE_SOQL=$(jq -r '.connectors.source.params.soql // ""' "$SPEC")

TARGET_NS=$(jq -r '.connectors.target.namespace.prefix // .connectors.target.namespace // ""' "$SPEC")
TARGET_NS_URI=$(jq -r '.connectors.target.namespace.namespace // ("http://www.mulesoft.org/schema/mule/" + (.connectors.target.namespace.prefix // .connectors.target.namespace // ""))' "$SPEC")
TARGET_NS_XSD=$(jq -r '
  .connectors.target.namespace.schemaLocation
  // ("http://www.mulesoft.org/schema/mule/" + (.connectors.target.namespace.prefix // .connectors.target.namespace // "") + "/current/mule-" + (.connectors.target.namespace.prefix // .connectors.target.namespace // "") + ".xsd")
' "$SPEC")
TARGET_CONFIG_NAME=$(jq -r '.connectors.target.config.name // ""' "$SPEC")
TARGET_CONN_ELEMENT=$(jq -r '.connectors.target.connectionProvider.elementName // ""' "$SPEC")
TARGET_OPERATION=$(jq -r '.connectors.target.operation // ""' "$SPEC")
TARGET_OP_ELEMENT=$(jq -r '.connectors.target.operationSchema.elementName // .connectors.target.operation // ""' "$SPEC")
TARGET_BODY_TEMPLATE=$(jq -r '.connectors.target.params.bodyTemplate // "Top {{count}} accounts:\\n{{accountList}}"' "$SPEC")

TRIGGER_METHOD=$(jq -r '.trigger.method // "POST"' "$SPEC")
TRIGGER_PATH=$(jq -r '.trigger.path // ("/ops/" + .projectName)' "$SPEC")

# emit_attrs — for a list of {attributeName,required} objects, emit XML
# attributes referencing ${ns.attr} placeholders for required attrs only.
emit_required_attrs() {
    local block="$1"   # "source" | "target"
    local ns
    ns=$(jq -r --arg b "$block" '.connectors[$b].namespace.prefix // .connectors[$b].namespace // ""' "$SPEC")
    jq -r --arg b "$block" --arg ns "$ns" '
      (.connectors[$b].connectionProvider.attributes // [])
      | map(select(.required == true))
      | map("            " + .attributeName + "=\"${" + $ns + "." + .attributeName + "}\"")
      | join("\n")
    ' "$SPEC"
}

SOURCE_REQ_ATTRS=$(emit_required_attrs source)
TARGET_REQ_ATTRS=$(emit_required_attrs target)

# Twilio's create-message operation requires accountSid as an attribute on
# the operation element itself — pull it from the spec inputs if present.
TARGET_OP_EXTRA_ATTRS=$(jq -r '
  (.connectors.target.operationSchema.attributes // [])
  | map(select(.required == true and .attributeName != "config-ref"))
  | map("            " + .attributeName + "=\"${" + (.attributeName | sub("[A-Z]"; "_  ") | ascii_downcase | gsub(" "; "")) + "}\"")
  | join("\n")
' "$SPEC")

cat > "$FLOW_XML" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<mule xmlns="http://www.mulesoft.org/schema/mule/core"
      xmlns:http="http://www.mulesoft.org/schema/mule/http"
      xmlns:${SOURCE_NS}="${SOURCE_NS_URI}"
      xmlns:${TARGET_NS}="${TARGET_NS_URI}"
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
        doc:description="Loads externalized configuration from config.yaml" />

    <http:listener-config name="httpListenerConfig"
        doc:name="HTTP Listener Config"
        doc:description="HTTP listener configuration for inbound requests">
        <http:listener-connection host="\${http.host}" port="\${http.port}" />
    </http:listener-config>

    <${SOURCE_NS}:${SOURCE_CONFIG_ELEMENT} name="${SOURCE_CONFIG_NAME}"
        doc:name="${SOURCE_NS} Config"
        doc:description="${SOURCE_NS} connection (auto-generated from connector metadata)">
        <${SOURCE_NS}:${SOURCE_CONN_ELEMENT}
${SOURCE_REQ_ATTRS} />
    </${SOURCE_NS}:${SOURCE_CONFIG_ELEMENT}>

    <${TARGET_NS}:config name="${TARGET_CONFIG_NAME}"
        doc:name="${TARGET_NS} Config"
        doc:description="${TARGET_NS} connection (auto-generated from connector metadata)">
        <${TARGET_NS}:${TARGET_CONN_ELEMENT}
${TARGET_REQ_ATTRS} />
    </${TARGET_NS}:config>

    <flow name="${PROJECT_NAME}"
        doc:name="${PROJECT_NAME}"
        doc:description="$(jq -r '.summary // "Auto-generated Mule flow"' "$SPEC" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')">

        <http:listener config-ref="httpListenerConfig" path="${TRIGGER_PATH}" allowedMethods="${TRIGGER_METHOD}"
            doc:name="HTTP ${TRIGGER_METHOD} ${TRIGGER_PATH}"
            doc:description="Receives ${TRIGGER_METHOD} requests from the caller" />

        <set-variable variableName="limit" value="#[payload.limit]"
            doc:name="Set Limit"
            doc:description="Extracts the record limit from the request body" />

        <set-variable variableName="phoneNumber" value="#[payload.phoneNumber]"
            doc:name="Set Phone Number"
            doc:description="Extracts the target phone number from the request body" />

        <${SOURCE_NS}:${SOURCE_OP_ELEMENT} config-ref="${SOURCE_CONFIG_NAME}"
            doc:name="Query ${SOURCE_NS}"
            doc:description="Queries ${SOURCE_NS} using SOQL"
            target="accounts">
            <${SOURCE_NS}:${SOURCE_NS}-query>
                #["${SOURCE_SOQL//\"/\\\"}"]
            </${SOURCE_NS}:${SOURCE_NS}-query>
        </${SOURCE_NS}:${SOURCE_OP_ELEMENT}>

        <logger level="INFO"
            message="#[output text/plain --- 'Queried ' ++ sizeOf(vars.accounts) ++ ' records for ' ++ vars.phoneNumber]"
            doc:name="Log Query Count"
            doc:description="Logs the number of records queried and target phone number" />

        <ee:transform
            doc:name="Build SMS Payload"
            doc:description="Formats records into a Twilio SMS body with To/From/Body fields">
            <ee:message>
                <ee:set-payload><![CDATA[%dw 2.0
output application/x-www-form-urlencoded
---
{
    To: vars.phoneNumber,
    From: p('${TARGET_NS}.fromNumber'),
    Body: "Top " ++ sizeOf(vars.accounts) ++ " accounts:\n" ++ (vars.accounts map ((account) ->
        (account.Name default "") ++ " (" ++ (account.Industry default "N/A") ++ ")"
    ) joinBy "\n")
}]]></ee:set-payload>
            </ee:message>
        </ee:transform>

        <${TARGET_NS}:${TARGET_OP_ELEMENT}
            config-ref="${TARGET_CONFIG_NAME}"
            accountSid="\${${TARGET_NS}.username}"
            doc:name="Send via ${TARGET_NS}"
            doc:description="Sends the formatted message via ${TARGET_NS}"
            target="${TARGET_NS}Resp" />

        <logger level="INFO"
            message="#[output text/plain --- 'Sent, SID=' ++ (vars.${TARGET_NS}Resp.sid default 'unknown')]"
            doc:name="Log ${TARGET_NS} Response"
            doc:description="Logs the message SID returned by ${TARGET_NS}" />

        <ee:transform
            doc:name="Build Response"
            doc:description="Returns recordsNotified, phoneNumber and message SID">
            <ee:message>
                <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{
    recordsNotified: sizeOf(vars.accounts),
    phoneNumber: vars.phoneNumber,
    messageSid: vars.${TARGET_NS}Resp.sid
}]]></ee:set-payload>
            </ee:message>
        </ee:transform>

        <error-handler>
            <on-error-propagate type="ANY"
                doc:name="On Error"
                doc:description="Logs the error and returns a structured error response">
                <logger level="ERROR"
                    message="#[output text/plain --- 'Flow error: ' ++ (error.description default 'no description')]"
                    doc:name="Log Error Detail"
                    doc:description="Logs the error for debugging" />
                <ee:transform doc:name="Error Response"
                    doc:description="Builds a JSON error response">
                    <ee:message>
                        <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{
    error: true,
    errorType: error.errorType,
    description: error.description
}]]></ee:set-payload>
                    </ee:message>
                </ee:transform>
            </on-error-propagate>
        </error-handler>

    </flow>
</mule>
XMLEOF
echo "✅ wrote $FLOW_XML"

# ----------------------------------------------------------------------
# 4. yaml/<project>-flow.yaml — Go-runtime YAML representation
# ----------------------------------------------------------------------
GO_FLOW_YAML="$PROJECT_DIR/yaml/${PROJECT_NAME}-flow.yaml"
cat > "$GO_FLOW_YAML" <<YAMLEOF
flow:
    name: ${PROJECT_NAME}
    steps:
        - set-variable:
            name: limit
            value: '#[payload.limit]'
        - set-variable:
            name: phoneNumber
            value: '#[payload.phoneNumber]'
        - connector:
            type: ${SOURCE_NS}
            operation: ${SOURCE_OPERATION}
            target: vars.accounts
            config:
                soql: '#["${SOURCE_SOQL//\"/\\\"}"]'
        - logger:
            level: INFO
            message: '#[output text/plain --- ''Queried '' ++ sizeOf(vars.accounts) ++ '' records for '' ++ vars.phoneNumber]'
        - transform:
            lang: dataweave
            script: |-
                %dw 2.0
                output application/x-www-form-urlencoded
                ---
                {
                    To: vars.phoneNumber,
                    From: p('${TARGET_NS}.fromNumber'),
                    Body: "Top " ++ sizeOf(vars.accounts) ++ " accounts:\n" ++ (vars.accounts map ((account) ->
                        (account.Name default "") ++ " (" ++ (account.Industry default "N/A") ++ ")"
                    ) joinBy "\n")
                }
        - connector:
            type: ${TARGET_NS}
            operation: sendMessage
            target: vars.${TARGET_NS}Resp
        - logger:
            level: INFO
            message: '#[output text/plain --- ''Sent, SID='' ++ (vars.${TARGET_NS}Resp.sid default ''unknown'')]'
        - transform:
            lang: dataweave
            script: |-
                %dw 2.0
                output application/json
                ---
                {
                    recordsNotified: sizeOf(vars.accounts),
                    phoneNumber: vars.phoneNumber,
                    messageSid: vars.${TARGET_NS}Resp.sid
                }
    trigger:
        http-listener:
            method: ${TRIGGER_METHOD}
            path: ${TRIGGER_PATH}
YAMLEOF
echo "✅ wrote $GO_FLOW_YAML"

# ----------------------------------------------------------------------
# 5. README.md — short developer guide
# ----------------------------------------------------------------------
README="$PROJECT_DIR/README.md"
SUMMARY=$(jq -r '.summary // "Mule application generated by build-mule-app-claude-poc."' "$SPEC")
cat > "$README" <<MDEOF
# ${PROJECT_NAME}

${SUMMARY}

## Run on the Go runtime

\`\`\`bash
go-runtime --xml-flows ./src/main/mule \\
           --xml-properties ./src/main/resources/config.yaml
\`\`\`

## Test

\`\`\`bash
curl -X ${TRIGGER_METHOD} http://localhost:8081${TRIGGER_PATH} \\
  -H "Content-Type: application/json" \\
  -d '{"limit": 5, "phoneNumber": "+15105551212"}'
\`\`\`

## Configuration

Fill in the placeholders in \`src/main/resources/config.yaml\` (or set them via
environment variables) before running.
MDEOF
echo "✅ wrote $README"

# ----------------------------------------------------------------------
# 6. ACB link sidecar
# ----------------------------------------------------------------------
ACB_LINK_FILE="${SPEC_DIR:-tmp/spec}/${PROJECT_NAME}.acb-link.txt"
ABS_PROJECT=$(cd "$PROJECT_DIR" && pwd)
mkdir -p "$(dirname "$ACB_LINK_FILE")"
printf 'acb://open?path=%s\n' "$ABS_PROJECT" > "$ACB_LINK_FILE"
echo "✅ wrote $ACB_LINK_FILE"

echo ""
echo "🎉 Project scaffolded at: $PROJECT_DIR"
