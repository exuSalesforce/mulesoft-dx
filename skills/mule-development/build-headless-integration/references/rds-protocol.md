# Remote Design Service (RDS) wire protocol

The skill (and ACB) talk to RDS over plain HTTP/JSON. The contract is fixed by:

- Java client: `HttpRemoteDesignServiceClient.java` in the `mule-dx-mule-dev-plugin`
- Container manager: `LocalRdsContainer.java` in the same plugin
- Selection logic: `RemoteDesignServiceClientFactory.java`
- Real RDS server (Go): `dservicex/` in the sibling go-runtime checkout
- End-to-end test: `testConnectionRds.integration.test.ts` in `mule-dx-mule-dev-vscode/src/test-emulator/test/`

The skill targets the **real Go RDS only**. There is no stub. RDS is brought up by `go-runtime/start-rds.sh` (a Docker Compose wrapper) and proxies test-connection calls to ConnectivityService over gRPC; calls hit real connector binaries (`*.wasm` modules) and exercise actual auth flows.

## Endpoints

### `GET /healthz`

Liveness probe. `LocalRdsContainer` polls this before any call and during container startup. The skill's `ensure_rds.sh` polls it too.

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

- `connector` — the connector name registered in `connector-service/config.yaml` in the go-runtime checkout. The Java side calls it "connector prefix".
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

5xx responses are infrastructure faults (e.g. RDS up but `connector-service` unreachable); the Java client maps these to `result.exception` rather than treating them as rejected credentials. Real RDS specifically returns 502 when ConnectivityService is unreachable.

### `GET /v1/connectors`

Lists which connector binaries the running ConnectivityService has loaded.

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

The skill's `scripts/list_rds_connectors.sh` calls this and annotates each entry with whether the connector is "pickable" (has a `/descriptor` available — see below).

### `GET /v1/connectors/{name}/descriptor`

Return all three design-time artifacts (extension-model + dsl + xsd) in **one atomic response**. This is the endpoint the ACB plugin's `ManifestRdsExtensionModelSource` and the skill's `fetch_bundle.sh` call. One request per connector, no consistency window across three files.

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

Bundle layout under `--bundles-dir` (all three forms supported transparently):

```
<bundles-dir>/<name>/extension-model.json              ← canonical (curated bundle)
<bundles-dir>/<name>/testdata/extension-model.json     ← go-runtime/connectors/<name>/testdata/
<bundles-dir>/<name>/testdata/extension-model-go.json  ← Go-emitter output, fallback
```

In docker-compose, RDS mounts `../connectors:/bundles:ro` so the unchanged `connectors/<name>/testdata/` layout works directly.

### `GET /v1/connectors/{name}/extension-model` and `GET /v1/connectors/{name}/dsl` (per-artifact, secondary)

Return the connector's `extension-model.json` or `dsl.json` only. Useful for clients that already have the other artifacts cached and want to refresh just one. **Use `/descriptor` for the standard render path** — it's atomic.

## Future endpoints (recommendations for the RDS team)

### `GET /v1/exchange/search?q=<term>` (lower priority)

Proxy to Anypoint Exchange to discover Java/MTF connectors that aren't on the Go path yet. Useful when headless flows want to use a connector RDS doesn't host. Could live in `dservicex` as an HTTP-only addition. Same shape as `anypoint-cli-v4 exchange asset list --type extension --search <term>`:

```http
GET /v1/exchange/search?q=salesforce
→ 200 { "results": [ { "groupId": "com.mulesoft.connectors", "assetId": "mule-salesforce-connector", "version": "11.4.0", ... }, ... ] }
```

Lower priority because the connectors RDS already loads cover Demo 2.

## Mode selection (env)

`RemoteDesignServiceClientFactory.create(...)` reads each setting as a JVM system property first (`-Dmule.dx.rds.mode`) and falls back to the env var.

| Env var | System property | Default | Effect |
| --- | --- | --- | --- |
| `MULE_DX_RDS_MODE` | `mule.dx.rds.mode` | _unset_ | Set to `dev` to enable the HTTP client. Anything else → production stub (returns "not available"). |
| `MULE_DX_RDS_URL` | `mule.dx.rds.url` | `http://localhost:8090` | Base URL for the dev HTTP client. |
| `MULE_DX_RDS_COMPOSE_DIR` | `mule.dx.rds.compose.dir` | _unset_ | Directory holding `docker-compose.yaml`; if set and `/healthz` is unreachable, `LocalRdsContainer` runs `docker compose up -d --build rds connector-service`. |

The skill also reads:

| Env var | Effect |
| --- | --- |
| `GO_RUNTIME` | Override the go-runtime checkout path (default: `$HOME/Salesforce/workspace/go-runtime`). Read by `start_real_rds.sh`. |

## Architecture

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

The skill's `ensure_rds.sh` calls `start_real_rds.sh` (which delegates to the above) when RDS isn't already reachable.

## Telling ACB about a running RDS

```bash
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://localhost:8090
```

In ACB's launch config or via `~/.zshenv` so VS Code inherits it.
