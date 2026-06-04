#!/usr/bin/env bash
# Phase 2 Step 9 (second half): materialize the project layout from tmp/design-spec.json.
#
# Writes the headless / Go-connector project:
#   <projectDir>/
#     .mule/project.json           # versionless descriptor (deps + goConnectors inline)
#     pom.xml                      # stub mirror, until WorkspaceManager supports no-pom
#     mule-artifact.json           # runtime metadata
#     .go-connectors.json          # bundle index DefaultJsonExtensionModelSource expects
#     go-connectors/<name>/        # copy of the picked Go bundle(s)
#     src/main/resources/config.yaml      # credential placeholders
#     (the agent generates src/main/mule/<name>.xml itself, against the digest)
#
# The agent generates the flow XML inline because it has the connector digest in
# context — emitting an LLM-generated XML file from bash would be silly.
#
# Usage: create_versionless_project.sh <projectDir>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_DIR="${WS_DIR:-$HOME/Salesforce/projects/headless}"
TMP_DIR="${TMP_DIR:-$WS_DIR/tmp}"
SPEC_FILE="$TMP_DIR/design-spec.json"

PROJECT_DIR="${1:-}"
if [[ -z "$PROJECT_DIR" ]]; then
  echo "Usage: create_versionless_project.sh <projectDir>" >&2
  exit 2
fi

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "no design spec at $SPEC_FILE (run commit_design_spec.sh first)" >&2
  exit 1
fi

PROJECT_NAME="$(jq -r '.projectName' "$SPEC_FILE")"
MULE_VERSION="$(jq -r '.muleVersion // "4.11.0"' "$SPEC_FILE")"
JAVA_VERSION="$(jq -r '.javaVersion // "17"' "$SPEC_FILE")"
PROJECT_VERSION="$(jq -r '.projectVersion // "1.0.0-SNAPSHOT"' "$SPEC_FILE")"

mkdir -p "$PROJECT_DIR/.mule" \
         "$PROJECT_DIR/src/main/mule" \
         "$PROJECT_DIR/src/main/resources" \
         "$PROJECT_DIR/src/test/mule" \
         "$PROJECT_DIR/go-connectors"

# 1) .mule/project.json — versionless descriptor with deps inline.
DEPS_JSON="$(jq '.dependencies // []' "$SPEC_FILE")"
GO_CONNECTORS_JSON="$(jq '[.picks[] | {name: .prefix, path: ("./go-connectors/" + .bundle)}]' "$SPEC_FILE")"

jq -n \
  --arg name "$PROJECT_NAME" \
  --arg version "$PROJECT_VERSION" \
  --arg muleVersion "$MULE_VERSION" \
  --arg javaVersion "$JAVA_VERSION" \
  --argjson deps "$DEPS_JSON" \
  --argjson goConnectors "$GO_CONNECTORS_JSON" \
  '{
    modelVersion: "1.1.0",
    name: $name,
    version: $version,
    natures: ["mule"],
    components: [],
    muleVersion: $muleVersion,
    javaVersion: $javaVersion,
    dependencies: $deps,
    sharedLibraries: [],
    goConnectors: $goConnectors
  }' >"$PROJECT_DIR/.mule/project.json"

# 2) .go-connectors.json — top-level bundle index (DefaultJsonExtensionModelSource reads this).
jq -n --argjson connectors "$GO_CONNECTORS_JSON" \
  '{ version: 1, connectors: $connectors }' \
  >"$PROJECT_DIR/.go-connectors.json"

# 3) Copy each picked Go bundle into go-connectors/<bundle>/.
while IFS=$'\t' read -r BUNDLE BUNDLE_SOURCE; do
  [[ -z "$BUNDLE" ]] && continue
  DEST="$PROJECT_DIR/go-connectors/$BUNDLE"
  rm -rf "$DEST"
  cp -R "$BUNDLE_SOURCE" "$DEST"
done < <(jq -r '.picks[] | [.bundle, .bundleSource] | @tsv' "$SPEC_FILE")

# 4) mule-artifact.json — minimal shape per testdata/apps/salesforce-accounts-to-twilio
# reference: just minMuleVersion + javaSpecificationVersions. The Go runtime / RDS path
# does not need requiredProduct or classLoaderModelLoaderDescriptor — the
# DefaultJsonExtensionModelSource path handles classloading via .go-connectors.json.
cat >"$PROJECT_DIR/mule-artifact.json" <<JSON
{
  "minMuleVersion": "$MULE_VERSION",
  "javaSpecificationVersions": ["$JAVA_VERSION"]
}
JSON

# 5) Stub pom.xml — patterned on testdata/apps/salesforce-accounts-to-twilio/pom.xml.
# Carries no connector dependencies (Go connectors aren't Maven artifacts), but matches
# the standard Mule 4 packaging so tooling that still reads pom.xml stays happy. Will
# become unnecessary once WorkspaceManagerImpl supports versionless project descriptors.
cat >"$PROJECT_DIR/pom.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         http://maven.apache.org/maven-v4_0_0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>com.example.headless</groupId>
    <artifactId>$PROJECT_NAME</artifactId>
    <version>$PROJECT_VERSION</version>
    <packaging>mule-application</packaging>

    <name>$PROJECT_NAME</name>

    <properties>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <project.reporting.outputEncoding>UTF-8</project.reporting.outputEncoding>
        <app.runtime>$MULE_VERSION</app.runtime>
        <mule.maven.plugin.version>4.7.0</mule.maven.plugin.version>
    </properties>

    <build>
        <plugins>
            <plugin>
                <groupId>org.mule.tools.maven</groupId>
                <artifactId>mule-maven-plugin</artifactId>
                <version>\${mule.maven.plugin.version}</version>
                <extensions>true</extensions>
            </plugin>
        </plugins>
    </build>
</project>
XML

# 6) src/main/resources/config.yaml — keyed dot-notation matching the reference flow:
#   <connectionKey>:
#     <field1>: "${ENV_OR_DEFAULT}"
#     ...
# Required fields come from the picked provider's required-param set in the digest.
# Trigger-related keys (http.host, http.port for HTTP listener) are emitted unconditionally
# when the design-spec trigger references them.
TRIGGER_KIND="$(jq -r '.trigger.kind // "scheduler"' "$SPEC_FILE")"

{
  echo "# Configuration for headless integration: $PROJECT_NAME"
  echo "# Each value is an environment-variable reference Mule resolves at runtime."
  echo "# Override by exporting the matching env var or editing this file directly."
  echo

  # Trigger config (only when the trigger needs externalized settings)
  if [[ "$TRIGGER_KIND" == "http-listener" ]]; then
    echo "# HTTP listener (trigger)"
    echo "http:"
    echo "  host: \"\${HTTP_HOST}\""
    echo "  port: \"\${HTTP_PORT}\""
    echo
  fi

  # Connection-provider blocks (one per .connections[] entry).
  # Reads the rich digest at tmp/connector-metadata/<nick>-digest.json — the flat
  # <nick>.json file emitted alongside doesn't carry parameter detail.
  # Two-pass jq: pass 1 produces plain rows {scope, env, key, default, allowed, description},
  # pass 2 formats the YAML so we don't have to fight bash/jq quoting around `, `.
  for digest in "$TMP_DIR/connector-metadata"/*-digest.json; do
    [[ -f "$digest" ]] || continue
    jq -r --slurpfile spec "$SPEC_FILE" '
      [
        $spec[0].connections[] as $c
        | ($spec[0].picks[] | select(.nick == $c.nick)) as $pick
        | (.configurations[0].connectionProviders[] | select(.name == $c.providerName)) as $prov
        | $prov.parameterGroups[].parameters[]
        | select(.required)
        | {nick: $c.nick, prefix: $pick.prefix, providerName: $c.providerName,
           name: .name,
           defaultValue: (.defaultValue // ""),
           allowedValues: (if .allowedValues then (.allowedValues | join(", ")) else "" end),
           description: (.description // "")}
      ]
      | group_by(.nick)
      | .[]
      | (.[0]) as $h
      | "# \($h.prefix) (\($h.providerName) auth)",
        "\($h.nick):",
        "  \($h.providerName):",
        (.[]
          | (([$h.nick, $h.providerName, .name] | map(ascii_upcase | gsub("[^A-Z0-9]"; "_")) | join("_"))) as $env
          | (if .description != "" then "    # \(.description)" else empty end),
            (if .allowedValues != "" then "    # allowed: \(.allowedValues)" else empty end),
            (if .defaultValue != "" then "    # default: \(.defaultValue)" else empty end),
            "    \(.name): \"${\($env)}\""),
        ""
    ' "$digest" 2>/dev/null
  done
} >"$PROJECT_DIR/src/main/resources/config.yaml"

# 6b) If config.yaml only has the header comments (no real keys), drop a one-line stub.
if ! grep -q '^[a-z]' "$PROJECT_DIR/src/main/resources/config.yaml"; then
  echo "# No required configuration values for $PROJECT_NAME." \
    >"$PROJECT_DIR/src/main/resources/config.yaml"
fi

echo "$PROJECT_DIR"
