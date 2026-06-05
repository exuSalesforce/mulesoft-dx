#!/usr/bin/env bash
#
# Copyright (c) 2026, Salesforce, Inc.
# All rights reserved.
# For full license text, see the LICENSE.txt file
#
# Part of build-mule-app-claude-poc skill.
#
# Step 5 helper — slice one operation's full schema out of the cached
# connector descriptor and write it to its own file. This is a local
# jq filter — no RDS call. The Go-runtime RDS does not expose a
# per-operation endpoint; the full operation schema is already nested
# inside the descriptor that describe_connector.sh fetched in Step 4.
#
# Output combines two slices for downstream consumers:
#   - extensionModel.configurations[*].operationModels[<op>]   (semantics)
#   - dsl.operations.<op>                                       (XML mapping)
#
# Usage:
#   scripts/describe_operation.sh <connector-id> <operation-name> [<nickname>]
#
# Where:
#   <connector-id>    — RDS id slug (e.g. "salesforce", "twilio")
#   <operation-name>  — operation name from the descriptor's operationModels
#   <nickname>        — optional short label used in filenames; defaults to <connector-id>
#
# Output:
#   tmp/connector-metadata/<nickname>.<operation>.json
#     {
#       "name":           "query",
#       "elementName":    "query",
#       "prefix":         "salesforce",
#       "namespace":      "http://www.mulesoft.org/schema/mule/salesforce",
#       "model":          { ...extensionModel.operations[op]... },
#       "dsl":            { ...dsl.operations[op]... },
#       "attributes":     [ { name, required, type, expressionSupport,
#                              defaultValue, asAttribute, asChild } ],
#       "errorTypes":     [ ... ]
#     }
#
# `attributes` is the flat list the scaffolder consumes: each parameter
# from extensionModel + dsl, with `asAttribute`/`asChild` flags lifted
# from dsl.operations.<op>.attributes.<paramName>. The scaffolder uses
# those flags to decide whether to emit each parameter as an XML
# attribute or as a nested child element.
#
# Exit code:
#   0  success
#   1  missing args / cached descriptor not found / op not in descriptor
set -euo pipefail

usage() {
    echo "Usage: $0 <connector-id> <operation-name> [<nickname>]" >&2
    echo "  e.g. $0 salesforce query" >&2
    echo "       $0 twilio sendMessage twilio" >&2
}

CONNECTOR_ID="${1:-}"
OPERATION="${2:-}"
if [ -z "$CONNECTOR_ID" ] || [ -z "$OPERATION" ]; then
    usage
    exit 1
fi
NICKNAME="${3:-$CONNECTOR_ID}"

METADATA_DIR="${CONNECTOR_METADATA_DIR:-tmp/connector-metadata}"
DESCRIPTOR="$METADATA_DIR/${NICKNAME}.json"
OUT_JSON="$METADATA_DIR/${NICKNAME}.${OPERATION}.json"

if [ ! -f "$DESCRIPTOR" ]; then
    echo "❌ No cached descriptor at $DESCRIPTOR" >&2
    echo "   Run describe_connector.sh first:" >&2
    echo "     bash <skill-dir>/scripts/describe_connector.sh $CONNECTOR_ID $NICKNAME" >&2
    exit 1
fi

# Locate the operation. We search across every configuration's
# operationModels because some connectors split ops across configs (the
# canonical POC ones don't, but the filter is cheap).
OP_PRESENT=$(jq --arg op "$OPERATION" '
    [
      (.extensionModel.configurations // [])[]
      | (.operationModels // [])[]
      | select(.name == $op)
    ] | length
' "$DESCRIPTOR")

if [ "$OP_PRESENT" = "0" ]; then
    echo "❌ Operation '$OPERATION' not found in $DESCRIPTOR" >&2
    echo "   Available operations:" >&2
    jq -r '
      [(.extensionModel.configurations // [])[]
       | (.operationModels // [])[].name]
      | unique
      | .[] | "    - " + .
    ' "$DESCRIPTOR" >&2
    exit 1
fi

# Build the consolidated slice.
jq --arg op "$OPERATION" '
    .extensionModel as $em
    | .dsl as $dsl
    | (
        [
          ($em.configurations // [])[]
          | (.operationModels // [])[]
          | select(.name == $op)
        ] | first
      ) as $model
    | ($dsl.operations[$op] // null) as $opDsl
    | ($opDsl.attributes // {}) as $dslAttrs
    | {
        name:        $op,
        elementName: ($opDsl.elementName // $model.name),
        prefix:      ($opDsl.prefix // $em.xmlDsl.prefix),
        namespace:   ($opDsl.namespace // $em.xmlDsl.namespace),
        model:       $model,
        dsl:         $opDsl,
        attributes:  (
            [
              ($model.parameterGroupModels // [])[]
              | (.parameterModels // [])[]
              | . as $p
              | ($dslAttrs[$p.name] // {}) as $d
              | {
                  name:              $p.name,
                  required:          ($p.required // false),
                  type:              ($p.type.type // null),
                  expressionSupport: ($p.expressionSupport // null),
                  defaultValue:      ($p.defaultValue // null),
                  description:       ($p.description // ""),
                  asAttribute:       ($d.supportsAttributeDeclaration // true),
                  asChild:           ($d.supportsChildDeclaration // false),
                  childElementName:  ($d.elementName // "")
                }
            ]
        ),
        errorTypes: ($em.errors // [] | map(.type))
      }
' "$DESCRIPTOR" > "$OUT_JSON"

echo "✅ $NICKNAME [$OPERATION] → $OUT_JSON"
echo ""
echo "--- describe digest (operation: $OPERATION) ---"
jq '{
  name, elementName, prefix, namespace,
  attributes_count: (.attributes | length),
  required_attributes: (.attributes | map(select(.required)) | map(.name)),
  attribute_summary: (
    .attributes
    | map({name, required, type, asAttribute, asChild, expressionSupport})
  )
}' "$OUT_JSON"
