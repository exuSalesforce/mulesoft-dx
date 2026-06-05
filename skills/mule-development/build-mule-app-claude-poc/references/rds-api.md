# Remote Design Service (RDS) — API Contract

The Remote Design Service is the POC's authoritative source for connector
metadata. It runs as a Docker container next to the agent (default
`http://localhost:8090`) and exposes a small versioned REST API under the
`/v1` prefix. Health is unversioned at `/healthz`.

The RDS does **not** invent or normalize anything — it forwards the
descriptor JSON shipped inside each connector package (`connectors/<name>/descriptor/`
in the go-runtime repo) verbatim. The descriptor format is the same one
produced by Mule's extension-model exporter, so consumers that already
understand `org.mule.runtime.api.meta.model.ExtensionModel` can read these
responses directly.

---

## Endpoints

### `GET /healthz`

Used by `check_env.sh` to confirm the service is reachable. **Unversioned
— no `/v1` prefix.**

**Response (200):**

```json
{ "ready": true }
```

Any non-2xx response counts as a failure; `check_env.sh` writes the curl
exit code and body to `tmp/poc-env.json` and exits 1.

---

### `GET /v1/connectors`

Used by `list_connectors.sh`. Lists every connector the RDS knows about.
**No query parameters** — the RDS does not implement server-side
filtering. Filter client-side after fetching.

**Response (200):**

```json
{
  "connectors": [
    { "name": "salesforce", "operations": ["create", "delete", "describeSObject", "getUserInfo", "query", "retrieve", "update", "upsert"] },
    { "name": "http",       "operations": ["listener"] },
    { "name": "twilio",     "operations": ["createMessage", "sendMessage", "..."] }
  ]
}
```

The list response carries only the connector name and an array of
operation names. There is no `description`, `namespace`, or `version`
field at this level — those live in the per-connector descriptor.

`list_connectors.sh` unwraps the `.connectors` array, filters
client-side on the optional CLI argument, persists the filtered array to
`tmp/connectors-list.json`, and prints a digest.

---

### `GET /v1/connectors/<name>/descriptor`

Used by `describe_connector.sh`. Returns the full descriptor for one
connector — the three artifacts the scaffolder needs:

- **`extensionModel`** — the connector's full extension-model JSON.
  Operations live at `extensionModel.configurations[].operationModels[]`,
  connection providers at `extensionModel.configurations[].connectionProviders[]`,
  the namespace at `extensionModel.xmlDsl`. Some connectors (Go-runtime
  Salesforce) ship with empty `connectionProviders` — the scaffolder
  handles this by emitting a bare config element.
- **`dsl`** — XML emission hints. `dsl.operations.<op>.attributes.<paramName>`
  carries `supportsAttributeDeclaration` and `supportsChildDeclaration`
  flags that determine whether each parameter is rendered as an XML
  attribute or as a nested child element. For both Salesforce `query` and
  Twilio `sendMessage`, every parameter is `supportsAttributeDeclaration:
  true` — the operation element is flat with all parameters as attributes.
- **`xsd`** — raw XSD text as a string. The scaffolder writes this to
  `tmp/connector-metadata/<nickname>.xsd` for an optional well-formedness
  check after XML emission.

**Response (200) — Salesforce example (truncated):**

```json
{
  "name": "salesforce",
  "version": "11.4.0",
  "extensionModel": {
    "name": "Salesforce",
    "version": "11.4.0",
    "vendor": "Mulesoft",
    "minMuleVersion": "4.4.0",
    "xmlDsl": {
      "prefix":         "salesforce",
      "namespace":      "http://www.mulesoft.org/schema/mule/salesforce",
      "schemaLocation": "http://www.mulesoft.org/schema/mule/salesforce/current/mule-salesforce.xsd",
      "schemaVersion":  "11.4.0",
      "xsdFileName":    "mule-salesforce.xsd"
    },
    "configurations": [
      {
        "name": "sfdc-config",
        "connectionProviders": [],
        "operationModels": [
          { "name": "query", "parameterGroupModels": [ { "parameterModels": [ { "name": "soql", "required": true, "type": { "type": "String" }, ... } ] } ] },
          ...
        ]
      }
    ],
    "errors": [ { "type": "MULE:ANY" }, ... ]
  },
  "dsl": {
    "operations": {
      "query": {
        "elementName": "query",
        "prefix":      "salesforce",
        "namespace":   "http://www.mulesoft.org/schema/mule/salesforce",
        "attributes": {
          "soql":        { "supportsAttributeDeclaration": true,  "supportsChildDeclaration": false, ... },
          "config-ref":  { "supportsAttributeDeclaration": true,  "supportsChildDeclaration": false, ... },
          ...
        }
      }
    },
    "configurations": {
      "sfdc-config": { "elementName": "sfdc-config", "prefix": "salesforce", ... }
    }
  },
  "xsd": "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xs:schema...>..."
}
```

**Response (200) — Twilio example (highly truncated):**

```json
{
  "name": "twilio",
  "version": "...",
  "extensionModel": {
    "xmlDsl": {
      "prefix":         "twilio",
      "namespace":      "http://www.mulesoft.org/schema/mule/twilio",
      "schemaLocation": "http://www.mulesoft.org/schema/mule/twilio/current/mule-twilio.xsd"
    },
    "configurations": [
      {
        "name": "config",
        "connectionProviders": [
          {
            "name": "account-sid-auth-token",
            "parameterGroupModels": [
              {
                "parameterModels": [
                  { "name": "username", "required": true,  "type": { "type": "String" } },
                  { "name": "password", "required": true,  "type": { "type": "String" } },
                  { "name": "baseUri",  "required": false, "defaultValue": "https://api.twilio.com" }
                ]
              }
            ]
          }
        ],
        "operationModels": [
          { "name": "sendMessage", ... },
          ...
        ]
      }
    ]
  },
  "dsl":  { "operations": { "sendMessage": { "elementName": "sendMessage", "attributes": { ... } } } },
  "xsd":  "..."
}
```

**Response (404):** The HTTP connector appears in `/v1/connectors` but
does not have a descriptor — `/v1/connectors/http/descriptor` returns 404.
The scaffolder uses a hand-written `<http:listener>` template in that case.

---

### Per-operation endpoint — NOT IMPLEMENTED

The Go-runtime RDS does **not** expose `GET /v1/connectors/{id}/operations/{op}`.
The full descriptor already contains every operation's full schema under
`extensionModel.configurations[].operationModels[]`, so no follow-up call
is needed.

`describe_operation.sh` is a local jq slice over the cached descriptor —
it reads `tmp/connector-metadata/<nickname>.json` and writes a flattened
`{ name, elementName, prefix, namespace, attributes[], errorTypes[] }`
slice to `tmp/connector-metadata/<nickname>.<op>.json`. The
`attributes[]` array merges parameter semantics from `extensionModel`
(required, type, expressionSupport, defaultValue) with XML-emission
flags from `dsl` (asAttribute, asChild, childElementName).

---

## Authentication

If `RDS_AUTH_TOKEN` is set in `tmp/poc-env.json`, every request adds:

```
Authorization: Bearer <RDS_AUTH_TOKEN>
```

The Go-runtime RDS does not enforce authentication in local Docker mode;
the scripts silently omit the header when the token is empty.

---

## Error envelope

Non-2xx responses return:

```json
{ "message": "<short error description>" }
```

(A handful of paths use `{"error": "..."}` instead — `_rds_lib.sh` prints
the body verbatim either way.) The scripts pretty-print the body to
stderr and exit 1; they never swallow an error or transform it into a
partial result.
