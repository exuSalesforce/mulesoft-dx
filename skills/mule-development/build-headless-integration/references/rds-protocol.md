# Remote Design Service (RDS) wire protocol

The skill (and ACB) talk to RDS over plain HTTP/JSON. The contract is fixed by:

- Java client: [HttpRemoteDesignServiceClient.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/HttpRemoteDesignServiceClient.java)
- Container manager: [LocalRdsContainer.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/LocalRdsContainer.java)
- Selection logic: [RemoteDesignServiceClientFactory.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/RemoteDesignServiceClientFactory.java)
- Persisted-config canvas path: [PersistedConnection.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/connectivity/PersistedConnection.java)
- Real RDS server (Go): [go-runtime/dservicex/](file:///Users/tzeree/Salesforce/workspace/go-runtime/dservicex/)
- End-to-end tests: [testConnection.integration.test.ts](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnection.integration.test.ts) (stub) and [testConnectionRds.integration.test.ts](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnectionRds.integration.test.ts) (live)

Two implementations satisfy the contract:

- The local Node stub at [helpers/rds_stub.mjs](../helpers/rds_stub.mjs) — wire-faithful, deterministic, no Docker, no connector binaries. Default backend.
- The real Go RDS at [go-runtime/dservicex/](file:///Users/tzeree/Salesforce/workspace/go-runtime/dservicex/) — proxies to ConnectivityService over gRPC; calls hit real connector binaries (`*.wasm` modules) and exercise the actual auth flow. Brought up via [go-runtime/start-rds.sh](file:///Users/tzeree/Salesforce/workspace/go-runtime/start-rds.sh).

## Endpoints

### `GET /healthz`

Liveness probe. `LocalRdsContainer` polls this before any call and during container startup.

Request: no body.

Response (200):

```json
{ "ready": true }
```

### `POST /v1/test-connection`

Validate credentials for a connection-provider configuration on a connector.

Request body:

```json
{
  "connector": "twilio",
  "providerName": "account-sid-auth-token",
  "config": {
    "username": "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "password": "the-auth-token"
  }
}
```

- `connector` — the connector name. For the real RDS this is the name registered in [connector-service/config.yaml](file:///Users/tzeree/Salesforce/workspace/go-runtime/services/connector-service/config.yaml); the stub doesn't validate this. The Java side calls it "connector prefix".
- `providerName` — the selected connection provider (`basic`, `jwt`, `account-sid-auth-token`, etc.). Empty string when no provider was chosen.
- `config` — flat field-name → value map. Field names match the provider's required parameters (see the skill's connector digest).

Response (200):

```json
{ "success": true,  "message": "connection successful" }
```

or

```json
{ "success": false, "message": "401 Unauthorized" }
```

The stub echoes a marker (`validated-by-stub-rds:<connector>:<provider>`) on success so test harnesses can assert the round-trip happened. Real RDS surfaces whatever the underlying connector returned.

5xx responses are infrastructure faults (e.g. RDS up but `connector-service` unreachable); the Java client maps these to `result.exception` rather than treating them as rejected credentials. Real RDS specifically returns 502 when ConnectivityService is unreachable.

### `GET /v1/connectors` (real RDS only)

Lists which connector binaries the running ConnectivityService has loaded. Added in [go-runtime ed5e196](file:///Users/tzeree/Salesforce/workspace/go-runtime/). The stub returns 404 for this endpoint.

Request: no body.

Response (200):

```json
{
  "connectors": [
    { "name": "salesforce", "operations": [...] },
    { "name": "twilio", "operations": [...] }
  ]
}
```

The skill's [scripts/list_rds_connectors.sh](../scripts/list_rds_connectors.sh) calls this and treats 404 as "stub mode, here's an empty list".

### `GET /v1/connectors/{name}/descriptor`

Return all three design-time artifacts (extension-model + dsl + xsd) in **one atomic response**. This is the endpoint the ACB plugin's [`ManifestRdsExtensionModelSource`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/ManifestRdsExtensionModelSource.java) and the skill's [`fetch_bundle.sh`](../scripts/fetch_bundle.sh) call. One request per connector, no consistency window across three files. Local Node stub does NOT implement this — only the real Go RDS does.

```http
GET /v1/connectors/twilio/descriptor
→ 200 application/json

{
  "name": "twilio",
  "version": "4.2.9",
  "extensionModel": { ... },   // verbatim extension-model.json (object, not string)
  "dsl": { ... } | null,       // verbatim dsl.json, or null when the connector ships none
  "xsd": "<?xml ... ?>"        // verbatim extension.xsd text (XML, not JSON)
}

GET /v1/connectors/<unknown>/descriptor
→ 404 { "error": "bundle not found", "connector": "<name>", "file": "extension-model.json" }
```

Bundle layout under `--bundles-dir` (both supported transparently):

```
<bundles-dir>/<name>/extension-model.json              ← canonical (curated bundle)
<bundles-dir>/<name>/testdata/extension-model.json     ← go-runtime/connectors/<name>/testdata/
<bundles-dir>/<name>/testdata/extension-model-go.json  ← Go-emitter output, fallback
```

In docker-compose, RDS mounts `../connectors:/bundles:ro` so the unchanged `connectors/<name>/testdata/` layout works directly.

### `GET /v1/connectors/{name}/extension-model` (per-artifact, secondary)

Return the connector's `extension-model.json` only. Useful for clients that already have the other two artifacts cached and want to refresh just the model. Use `/descriptor` for the standard render path.

```http
GET /v1/connectors/twilio/extension-model
→ 200 application/json   <full ExtensionModel JSON>

GET /v1/connectors/<unknown>/extension-model
→ 404 { "error": "bundle not found", "connector": "<name>", "file": "extension-model.json" }
```

Bundle layout under `--bundles-dir` (both supported transparently):

```
<bundles-dir>/<name>/extension-model.json              ← canonical (curated bundle)
<bundles-dir>/<name>/testdata/extension-model.json     ← go-runtime/connectors/<name>/testdata/
<bundles-dir>/<name>/testdata/extension-model-go.json  ← Go-emitted filename, fallback
```

In docker-compose, RDS mounts `../connectors:/bundles:ro` so the unchanged `connectors/<name>/testdata/` layout works directly.

### `GET /v1/connectors/{name}/dsl` (per-artifact, secondary)

Return the connector's `dsl.json` only. Same caveat as `/extension-model` above — `/descriptor` is the standard path.

```http
GET /v1/connectors/twilio/dsl
→ 200 application/json   <full DSL JSON>

GET /v1/connectors/<unknown>/dsl
→ 404 { "error": "bundle not found", "connector": "<name>", "file": "dsl.json" }
```

## Future endpoints (recommendations for the RDS team)

### `GET /v1/exchange/search?q=<term>` (lower priority)

Proxy to Anypoint Exchange to discover Java/MTF connectors that aren't on the Go path yet. Useful when headless flows want to use a connector RDS doesn't host. Could also live in `dservicex` as an HTTP-only addition. Same shape as the old `anypoint-cli-v4 exchange asset list --type extension --search <term>`:

```http
GET /v1/exchange/search?q=salesforce
→ 200 { "results": [ { "groupId": "com.mulesoft.connectors", "assetId": "mule-salesforce-connector", "version": "11.4.0", ... }, ... ] }
```

Lower priority because the skill's static catalog covers Demo 2's needs.

## Mode selection (env)

`RemoteDesignServiceClientFactory.create(...)` reads each setting as a JVM system property first (`-Dmule.dx.rds.mode`) and falls back to the env var.

| Env var | System property | Default | Effect |
| --- | --- | --- | --- |
| `MULE_DX_RDS_MODE` | `mule.dx.rds.mode` | _unset_ | Set to `dev` to enable the HTTP client. Anything else → production stub (returns "not available"). |
| `MULE_DX_RDS_URL` | `mule.dx.rds.url` | `http://localhost:8090` | Base URL for the dev HTTP client. |
| `MULE_DX_RDS_COMPOSE_DIR` | `mule.dx.rds.compose.dir` | _unset_ | Directory holding `docker-compose.yaml`; if set and `/healthz` is unreachable, `LocalRdsContainer` runs `docker compose up -d --build rds connector-service`. |

The skill also reads its own:

| Env var | Effect |
| --- | --- |
| `MULE_DX_USE_REAL_RDS=1` or `MULE_DX_RDS_BACKEND=real` | `start_rds_stub.sh` defers to the real-RDS path instead of spawning the Node stub. Equivalent to passing `--real`. |
| `GO_RUNTIME` | Override the go-runtime checkout path (default: `~/Salesforce/workspace/go-runtime`). Read by `start_real_rds.sh`. |

## Backend choice — when to use which

| Backend | Pros | Cons | When to use |
| --- | --- | --- | --- |
| **Node stub** (default) | No Docker, no go-runtime, instant startup, deterministic | Doesn't actually authenticate — accepts any creds with username+password | Demo walkthroughs, offline development, CI without Docker |
| **Real RDS** (`--real`) | Real auth flow, real connector binaries, 401 on bad creds | Needs Docker + go-runtime checkout + WASM build (~minutes on first run) | End-to-end verification, debugging real connector behavior |

Both satisfy the same wire contract — the skill produces the same project regardless of which is running. Switching is a single env var.

## Architecture (real RDS)

```
ACB (MULE_DX_RDS_MODE=dev, MULE_DX_RDS_URL=http://localhost:8090)
  │
  └─► RDS  (:8090, dservicex/cmd/main.go)
        │
        └─► ConnectivityService  (:50051, gRPC + JSONCodec)
              │
              └─► connector .wasm  → real API (e.g. api.twilio.com)
```

`go-runtime/start-rds.sh` brings the whole stack up:
1. `go mod vendor` (sibling module `data-weave/go` is `replace`d).
2. `./deploy/build-wasm-modules.sh` — builds `salesforce.wasm`, `http.wasm`, `twilio.wasm`.
3. `docker compose up -d rds connector-service` — RDS on `:8090`, ConnectivityService on `:50051`.
4. Polls `/healthz` until ready.

## Telling ACB about a running RDS

```bash
# stub:
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://127.0.0.1:<stub-port>     # see tmp/rds.json

# real RDS (always 8090):
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://localhost:8090
```

In ACB's launch config or via `~/.zshenv` so VS Code inherits it.

## Local stub: extra debug endpoints

### `GET /_requests`

Returns the JSON-serialized request log. Useful for asserting the skill produced the right envelope.

```json
[
  { "at": "2026-06-04T00:38:49.470Z", "body": { "connector": "salesforce", "providerName": "basic", "config": { "username": "...", "password": "..." } } }
]
```

The real RDS does not have this endpoint.

## Stub policy (deterministic)

- Any value in `config` equal to literal `"FAIL"` → `{ success: false, message: "rejected by stub: a config value was \"FAIL\"" }`. Used to demo the failure UX.
- Missing `username` or `password` in `config` → `{ success: false, message: "rejected by stub: missing required credentials" }`.
- Otherwise → `{ success: true, message: "validated-by-stub-rds:<connector>:<providerName-or-default>" }`.

The marker `validated-by-stub-rds:...` is what proves the round-trip happened — same pattern as `RDS_MARKER` in [testConnection.integration.test.ts](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnection.integration.test.ts).
