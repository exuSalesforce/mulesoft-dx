# Reference flow shape

The agent generates `src/main/mule/<projectName>.xml` at Step 9 from the connector
digest. The shape below is the canonical pattern, modeled on
`go-runtime/testdata/apps/salesforce-accounts-to-twilio/src/main/mule/salesforce-accounts-to-twilio.xml` (in the sibling go-runtime checkout).
Match the structure, not the exact connectors — the connectors come from the user's picks.

## Required structural pieces (in order)

1. **`<mule>` root** — declare every namespace you'll use. Always include:
   - `xmlns="http://www.mulesoft.org/schema/mule/core"` (default)
   - `xmlns:doc="http://www.mulesoft.org/schema/mule/documentation"`
   - `xmlns:ee="http://www.mulesoft.org/schema/mule/ee/core"` (for `<ee:transform>`)
   - `xmlns:<prefix>` per picked connector (use `prefix`/`namespace` from `tmp/connector-choices/<nick>.json`)
   - `xmlns:http="http://www.mulesoft.org/schema/mule/http"` if the trigger or any operation is HTTP
   - `xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"`
   - `xsi:schemaLocation="..."` with one space-separated `<namespace> <schemaLocation>` pair per declared namespace (use the `schemaLocation` from each pick). Always include `core` and `ee/core` pairs.

2. **`<configuration-properties file="config.yaml" doc:name="..." doc:description="..." />`** — exactly once. Mule resolves `${dotted.key}` placeholders against this file.

3. **One `<http:listener-config>`, `<scheduler>` (no config object), or connector source** — the trigger. Only declare a top-level config when the trigger has one (e.g. HTTP listener does, scheduler doesn't).

4. **One `<prefix>:<config-element>` per picked connector**, child to `<mule>`. Inside, embed the chosen connection provider element (the digest's `provider element=...` line). Example:
   ```xml
   <salesforce:sfdc-config name="salesforceConfig" doc:name="Salesforce Config" doc:description="Salesforce connection (basic auth)">
     <salesforce:basic
       username="${salesforce.basic.username}"
       password="${salesforce.basic.password}"/>
   </salesforce:sfdc-config>
   ```
   The element name comes from the digest, not from training memory. The Java Salesforce connector uses `salesforce:basic-connection`; the Go bundle uses `salesforce:basic`. Use what's in the digest.

5. **One or more `<flow name="..." doc:name="..." doc:description="...">`** — each flow starts with the trigger, then a sequence of processors.

6. **Inside each flow, the standard Mule patterns:**
   - **Trigger first** (one of: `<scheduler>`, `<http:listener>`, `<prefix>:<source-element>`).
   - **`<set-variable>` for each input field** the trigger exposed but downstream code needs (`payload.limit` → `vars.limit`).
   - **Operations** with `config-ref="..."` matching the config element's `name`. Use `target="<varName>"` to capture output into a var instead of overwriting `payload`.
   - **`<ee:transform>`** for shaping payloads. DataWeave goes inside `<ee:set-payload>` with a CDATA block.
   - **`<logger level="INFO" message="..." />`** at key checkpoints — `#[output text/plain --- '...' ++ vars.x]` for variable interpolation.
   - **`<error-handler>` at the end of the flow** with `<on-error-propagate type="ANY">`. Inside, log the error and `<ee:transform>` to a structured response.

## DataWeave conventions

- `output application/json` for structured JSON, `application/x-www-form-urlencoded` for form posts (e.g. Twilio), `text/plain` for log messages.
- `vars.<name>` reads variables; `payload` reads the message; `p('<dotted.key>')` reads `config.yaml`.
- For loops: `vars.accounts map ((account) -> ...) joinBy "\n"`.

## Trigger options

Pick exactly one. The skeleton below shows HTTP listener — for the others, swap the trigger block.

**Scheduler** (no top-level config; replaces the `<http:listener-config>` and the `<http:listener>` line in the skeleton):
```xml
<scheduler doc:name="Every N seconds"
    doc:description="Polls <SOMETHING> on a fixed schedule">
    <scheduling-strategy>
        <fixed-frequency frequency="60000" timeUnit="MILLISECONDS"/>
    </scheduling-strategy>
</scheduler>
```

**Connector source** (no top-level config; replaces the `<http:listener-config>` and the `<http:listener>` line). Use when a picked connector exposes a source matching the trigger hint — read the digest's `sources:` line:
```xml
<<PREFIX>:<SOURCE_ELEMENT> config-ref="<connectorScope>Config"
    <SOURCE_REQUIRED_ATTR>="<SOURCE_REQUIRED_VALUE>"
    doc:name="<Source Display Name>"
    doc:description="Listens for <SOMETHING>"/>
```

## Skeleton (fill in connector specifics from the digest)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<mule xmlns="http://www.mulesoft.org/schema/mule/core"
      xmlns:http="http://www.mulesoft.org/schema/mule/http"
      xmlns:<PREFIX>="<NAMESPACE>"
      xmlns:ee="http://www.mulesoft.org/schema/mule/ee/core"
      xmlns:doc="http://www.mulesoft.org/schema/mule/documentation"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="
        http://www.mulesoft.org/schema/mule/core http://www.mulesoft.org/schema/mule/core/current/mule.xsd
        http://www.mulesoft.org/schema/mule/http http://www.mulesoft.org/schema/mule/http/current/mule-http.xsd
        <NAMESPACE> <SCHEMA_LOCATION>
        http://www.mulesoft.org/schema/mule/ee/core http://www.mulesoft.org/schema/mule/ee/core/current/mule-ee.xsd">

    <configuration-properties file="config.yaml"
        doc:name="Configuration Properties"
        doc:description="Loads externalized configuration from config.yaml" />

    <http:listener-config name="httpListenerConfig" doc:name="HTTP Listener Config">
        <http:listener-connection host="${http.host}" port="${http.port}" />
    </http:listener-config>

    <<PREFIX>:<CONFIG_ELEMENT> name="<connectorScope>Config"
        doc:name="<Connector> Config"
        doc:description="<Connector> connection (<provider> auth)">
        <<PREFIX>:<PROVIDER_ELEMENT>
            <REQUIRED_FIELD_1>="${<connectorScope>.<provider>.<REQUIRED_FIELD_1>}"
            <REQUIRED_FIELD_2>="${<connectorScope>.<provider>.<REQUIRED_FIELD_2>}" />
    </<PREFIX>:<CONFIG_ELEMENT>>

    <flow name="<flow-name>"
        doc:name="<Human readable flow name>"
        doc:description="<What this flow does, in one sentence>">

        <!-- Trigger: e.g. <http:listener>, <scheduler>, or <prefix>:<source> -->
        <http:listener config-ref="httpListenerConfig" path="/<path>" allowedMethods="POST"
            doc:name="HTTP POST /<path>"
            doc:description="<What this endpoint receives>" />

        <!-- Extract inputs into vars -->
        <set-variable variableName="<var>" value="#[payload.<field>]"
            doc:name="Set <Var>" doc:description="<what>" />

        <!-- Connector operations -->
        <<PREFIX>:<OP_ELEMENT> config-ref="<connectorScope>Config"
            doc:name="<Op label>" doc:description="<what it does>"
            target="<resultVar>">
            <!-- Inline DSL children if the op needs them -->
        </<PREFIX>:<OP_ELEMENT>>

        <!-- Transform / log / chain to next operation -->

        <error-handler>
            <on-error-propagate type="ANY"
                doc:name="On Error" doc:description="Logs and returns structured error">
                <logger level="ERROR"
                    message="#[output text/plain --- 'Flow error: ' ++ (error.description default 'no description')]"
                    doc:name="Log Error Detail" />
                <ee:transform doc:name="Error Response">
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
```

## Key rules (failure modes this exists to prevent)

- **Element names come from the digest, not from training memory.** Java connectors and Go connectors can use different element names for the same concept. The digest's `element=` field is authoritative.
- **`doc:name` and `doc:description` on every meaningful element.** Reference flow has them on configs, sources, operations, transforms, error handlers, and inner steps. They're how the canvas labels nodes; missing them shows up as raw XML element names in ACB.
- **Attribute names in the flow XML come from the digest's `parameterModels[].name` (or its dsl.json `attributes` keys).** Use the parameter `name` verbatim as the XML attribute name. Do not pluralize, camel-fy, or invent variants based on training memory. **Worked example:** the Go salesforce `query` op declares one required input named `soql`. The XML must read `soql="#[...]"`. Common wrong forms — pulled straight from the Java-connector schema or from training data — are `salesforceQuery`, `query`, `<salesforce:salesforce-query>...</salesforce:salesforce-query>` (child element). All three would fail the canvas validator. Only `soql=` is correct here.
- **Required parameter names come from the digest.** If a parameter isn't in the digest's `required=` list, it's not required — and if it's not in the digest at all, it's not a parameter of that operation.
- **`${...}` placeholders must match `config.yaml` keys.** The skill writes `config.yaml` with `<connectorScope>.<provider>.<field>` keys; flow XML must reference them in the same shape.
- **`xsi:schemaLocation` pairs match declared namespaces.** Every `xmlns:<prefix>` needs a matching pair. Missing pairs cause schema-aware editor features in ACB to silently fail.
- **One `<error-handler>` per flow.** Without it, errors propagate raw to the caller.

## Java vs Go connector schema differences

The reference XML linked below targets the **Java** Salesforce/Twilio connectors. Our Go-connector flow XML cannot match it byte-for-byte because the two connectors expose different element / attribute names for the same concepts:

| Concept | Java connector form | Go connector form (digest authoritative) |
|---|---|---|
| Salesforce basic provider element | `<salesforce:basic-connection>` | `<salesforce:basic>` |
| Twilio provider element | `<twilio:account-sid-auth-token-connection>` | `<twilio:account-sid-auth-token>` |
| Salesforce `query` SOQL parameter | child element `<salesforce:salesforce-query>` | flat attribute `soql=` |
| Twilio "create message" op element | `<twilio:create20100401-accounts-messagesjson-by-account-sid>` (kebab) | `<twilio:create20100401AccountsMessagesjsonByAccountSid>` (camel) |

Use the reference for **structure** (namespace setup, config + flow + error-handler shape, DataWeave conventions). Use the **digest** (and `dsl.json`) for **names** (elements, attributes, providers).

## Example: Salesforce → Twilio (real)

See `salesforce-accounts-to-twilio.xml` (in the sibling go-runtime checkout, under `testdata/apps/salesforce-accounts-to-twilio/src/main/mule/`) for a complete production-shaped example. It demonstrates:

- Multi-namespace `<mule>` root with EE + HTTP + two connectors.
- Two connector configs (Salesforce + Twilio) each with their connection-provider element.
- HTTP-triggered flow with input extraction, two operations chained via `target=`, two `<ee:transform>` blocks (one for the connector input, one for the response), and a complete error handler.
- DataWeave for both `application/x-www-form-urlencoded` (Twilio) and `application/json` (response).

**Reminder:** the reference uses the Java-connector forms (`salesforce:basic-connection`, child `<salesforce:salesforce-query>`, kebab-case Twilio op name). When generating against Go connectors, follow the table above — the forms differ.
