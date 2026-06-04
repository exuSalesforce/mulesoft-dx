# Remote Design Service (RDS) — API Contract

The Remote Design Service is the POC's authoritative source for connector
metadata. It runs as a Docker container next to the agent (default
`http://localhost:8090`) and exposes a small, **versionless** REST API: every
response describes the connector's *current* shape, with no `version` field
anywhere. Consumers — the bundled scripts in this skill, plus any future MCP
app — never have to negotiate connector versions.

This file documents what each script expects to receive, anchored against
real Mule 4 connector metadata captured locally under
`/Users/sathishpaul.leo/projects/mulesoft-dx/tmp/connector-metadata/`.

---

## Versionless principle

- No `version`, `groupId`, `assetId`, or `gav` fields anywhere in any response.
- Connectors are addressed by a stable `id` slug (`salesforce`, `twilio`,
  `http`, …). The id is the only handle the scripts need.
- The shape of a connector — its operations, sources, configs, attributes,
  child elements — IS the connector for the purposes of this POC. Whatever
  the RDS returns is what the scaffolder writes into the project.

---

## Endpoints

### `GET /healthz`

Used by `check_env.sh` to confirm the service is reachable.

**Response (200):**

```json
{ "status": "ok" }
```

Any non-2xx response counts as a failure; `check_env.sh` writes the curl
exit code and body to `tmp/poc-env.json` and exits 1.

---

### `GET /connectors`

Used by `list_connectors.sh`. List the connectors the RDS knows about,
optionally filtered by query string.

**Query parameters:**

| Param | Required | Description |
|---|---|---|
| `q` | optional | case-insensitive substring filter against `id`, `name`, `namespace`, `description` |

**Response (200):**

```json
[
  {
    "id": "salesforce",
    "name": "Salesforce Connector",
    "namespace": "salesforce",
    "description": "Salesforce CRM connector — sObject CRUD, SOQL/SOSL, bulk and metadata APIs."
  },
  {
    "id": "twilio",
    "name": "Twilio Connector",
    "namespace": "twilio",
    "description": "Send SMS, WhatsApp messages, and place voice calls via Twilio's REST APIs."
  },
  {
    "id": "http",
    "name": "HTTP Connector",
    "namespace": "http",
    "description": "HTTP listener and request connectors."
  }
]
```

**Empty result:** `[]` (200, not 404).

`list_connectors.sh` writes the array verbatim to `tmp/connectors-list.json`
and prints a digest in the form `<id>  <name>  <namespace>` (one connector
per line, padded for readability).

---

### `GET /connectors/<id>`

Used by `describe_connector.sh`. Return the full descriptor for one connector.

The response merges everything the agent needs to choose a config / operation
without a follow-up call: namespace info, the list of operation names, the
list of source names, and the configs each with the **fully-expanded
connection-provider schema** inlined (attributes + childElements). This is
what the predecessor skill called "config-detail" — folded into the connector
descriptor here so the POC doesn't need a second round trip.

**Response (200) — Salesforce example:**

```json
{
  "id": "salesforce",
  "name": "Salesforce Connector",
  "namespace": {
    "prefix": "salesforce",
    "namespace": "http://www.mulesoft.org/schema/mule/salesforce",
    "schemaLocation": "http://www.mulesoft.org/schema/mule/salesforce/current/mule-salesforce.xsd"
  },
  "operations": [
    "create", "delete", "query", "queryAll", "retrieve", "search", "update", "upsert"
  ],
  "sources": [
    "deleted-object-listener",
    "modified-object-listener",
    "new-object-listener",
    "replay-channel-listener",
    "replay-topic-listener"
  ],
  "configs": [
    {
      "name": "sfdc-config",
      "prefix": "salesforce",
      "elementName": "sfdc-config",
      "attributes": [
        { "attributeName": "name", "required": true,
          "description": "The identifier of this element used to reference it in other components" }
      ],
      "childElements": [],
      "connectionProviders": [
        {
          "name": "basic",
          "prefix": "salesforce",
          "elementName": "basic-connection",
          "attributes": [
            { "attributeName": "username",      "required": true },
            { "attributeName": "password",      "required": true },
            { "attributeName": "securityToken", "required": false },
            { "attributeName": "url",           "required": false }
          ],
          "childElements": []
        }
      ]
    }
  ],
  "errorTypes": [
    "MULE:ANY", "MULE:CONNECTIVITY",
    "SALESFORCE:CONNECTIVITY", "SALESFORCE:INSUFFICIENT_PERMISSIONS",
    "SALESFORCE:INVALID_INPUT", "SALESFORCE:INVALID_RESPONSE", "SALESFORCE:NOT_FOUND",
    "SALESFORCE:RETRY_EXHAUSTED", "SALESFORCE:TIMEOUT", "SALESFORCE:UNAVAILABLE"
  ]
}
```

**Response (200) — Twilio example:**

```json
{
  "id": "twilio",
  "name": "Twilio Connector",
  "namespace": { "prefix": "twilio" },
  "operations": [
    "create20100401-accounts-messagesjson-by-account-sid"
  ],
  "sources": [
    "on-new-message-listener"
  ],
  "configs": [
    {
      "name": "config",
      "prefix": "twilio",
      "elementName": "config",
      "attributes": [],
      "childElements": [],
      "connectionProviders": [
        {
          "name": "account-sid-auth-token",
          "prefix": "twilio",
          "elementName": "account-sid-auth-token-connection",
          "attributes": [
            { "attributeName": "username", "required": true },
            { "attributeName": "password", "required": true },
            { "attributeName": "baseUri",  "required": false, "defaultValue": "https://api.twilio.com" }
          ],
          "childElements": []
        }
      ]
    }
  ],
  "errorTypes": [ "MULE:ANY", "TWILIO:CONNECTIVITY", "TWILIO:RETRY_EXHAUSTED" ]
}
```

**Response (404):** `{ "error": "connector not found", "id": "<id>" }` —
`describe_connector.sh` echoes the body and exits 1.

`describe_connector.sh` writes the response verbatim to
`tmp/connector-metadata/<nickname>.json` and prints a digest matching the
existing `build-mule-integration` skill's shape so downstream agents see the
key fields without a follow-up `jq` call.

---

### `GET /connectors/<id>/operations/<operation-name>`

Used by `describe_operation.sh`. Return the full per-operation schema —
attributes, child elements, error types.

**Response (200) — Salesforce `query`:**

```json
{
  "name": "query",
  "prefix": "salesforce",
  "elementName": "query",
  "attributes": [
    { "attributeName": "config-ref", "required": true,
      "description": "The name of the configuration to be used to execute this component" },
    { "attributeName": "target", "required": false,
      "description": "The name of a variable on which the operation's output will be placed" },
    { "attributeName": "targetValue", "required": false,
      "defaultValue": "#[payload]", "expressionRequired": true,
      "description": "An expression that will be evaluated against the operation's output and the outcome of that expression will be stored in the target variable" }
  ],
  "childElements": [
    { "paramName": "salesforceQuery", "prefix": "salesforce",
      "elementName": "salesforce-query", "required": true }
  ],
  "errorTypes": [
    "MULE:ANY", "SALESFORCE:CONNECTIVITY",
    "SALESFORCE:INVALID_INPUT", "SALESFORCE:NOT_FOUND",
    "SALESFORCE:RETRY_EXHAUSTED", "SALESFORCE:TIMEOUT"
  ]
}
```

**Response (200) — Twilio `create20100401-accounts-messagesjson-by-account-sid`:**

```json
{
  "name": "create20100401-accounts-messagesjson-by-account-sid",
  "prefix": "twilio",
  "elementName": "create20100401-accounts-messagesjson-by-account-sid",
  "attributes": [
    { "attributeName": "config-ref", "required": true },
    { "attributeName": "accountSid", "required": true },
    { "attributeName": "target",      "required": false },
    { "attributeName": "targetValue", "required": false, "defaultValue": "#[payload]" }
  ],
  "childElements": [
    { "paramName": "body", "prefix": "twilio", "elementName": "body", "required": false }
  ],
  "errorTypes": [ "MULE:ANY", "TWILIO:CONNECTIVITY", "TWILIO:INVALID_INPUT" ]
}
```

**Response (404):** `{ "error": "operation not found", "id": "<id>", "operation": "<name>" }`.

`describe_operation.sh` writes the response verbatim to
`tmp/connector-metadata/<nickname>.<operation>.json`. The scaffolder reads
this file in Step 9 to assemble the operation's XML element.

---

## Authentication

If `RDS_AUTH_TOKEN` is set in `tmp/poc-env.json`, every request adds:

```
Authorization: Bearer <RDS_AUTH_TOKEN>
```

For local Docker development the token is typically empty; the scripts
silently omit the header in that case.

---

## Error envelope

For every non-2xx response, the body is expected to be:

```json
{ "error": "<short-message>", "details": "<optional long form>" }
```

The scripts pretty-print the body to stderr verbatim and exit 1 — they never
swallow an error or transform it into a partial result.
