# Remote Design Service (RDS) wire protocol

The skill (and ACB) talk to RDS over plain HTTP/JSON. The contract is fixed by:

- Java client: [HttpRemoteDesignServiceClient.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/HttpRemoteDesignServiceClient.java)
- Container manager: [LocalRdsContainer.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/LocalRdsContainer.java)
- Selection logic: [RemoteDesignServiceClientFactory.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/RemoteDesignServiceClientFactory.java)
- End-to-end test: [testConnection.integration.test.ts](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnection.integration.test.ts)

The local stub at [helpers/rds_stub.mjs](../helpers/rds_stub.mjs) implements this contract verbatim.

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
  "connector": "salesforce-go",
  "providerName": "basic",
  "config": {
    "username": "user@example.com",
    "password": "secret",
    "securityToken": "token"
  }
}
```

- `connector` — the connector name (Java side calls it the "connector prefix"; e.g. `salesforce-go`, `slack-go`). For the demo bundle the prefix is just `salesforce`.
- `providerName` — the selected connection provider (`basic`, `jwt`, etc.). Empty string when no provider was chosen.
- `config` — flat field-name → value map matching the provider's required parameters (see the skill's connector digest).

Response (200):

```json
{ "success": true,  "message": "validated-by-stub-rds:salesforce-go:basic" }
```

or

```json
{ "success": false, "message": "rejected by stub: a config value was \"FAIL\"" }
```

5xx responses are infrastructure faults (e.g. RDS up but `connector-service` unreachable); the Java client surfaces these as `result.exception` rather than treating them as a rejected credential.

## Mode selection (env)

`RemoteDesignServiceClientFactory.create(...)` reads each setting as a JVM system property first (`-Dmule.dx.rds.mode`) and falls back to the env var.

| Env var | System property | Default | Effect |
| --- | --- | --- | --- |
| `MULE_DX_RDS_MODE` | `mule.dx.rds.mode` | _unset_ | Set to `dev` to enable the HTTP client. Anything else → production stub (returns "not available"). |
| `MULE_DX_RDS_URL` | `mule.dx.rds.url` | `http://localhost:8090` | Base URL for the dev HTTP client. |
| `MULE_DX_RDS_COMPOSE_DIR` | `mule.dx.rds.compose.dir` | _unset_ | Directory holding `docker-compose.yaml`; if set and `/healthz` is unreachable, `LocalRdsContainer` runs `docker compose up -d --build rds connector-service`. |

For Demo 2 we run the local Node stub and tell ACB about it:

```bash
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://127.0.0.1:<stub-port>
```

When the real Go RDS lands in [go-runtime/deploy/docker-compose.yaml](file:///Users/tzeree/Salesforce/workspace/go-runtime/deploy/docker-compose.yaml), point `MULE_DX_RDS_URL` at it (or set `MULE_DX_RDS_COMPOSE_DIR=/Users/tzeree/Salesforce/workspace/go-runtime/deploy`) and the skill's stub becomes unnecessary.

## Local stub: extra debug endpoints

The stub at `helpers/rds_stub.mjs` adds a non-protocol endpoint for development:

### `GET /_requests`

Returns the JSON-serialized request log (most recent first ignored — it's append-only). Useful for asserting the skill produced the right envelope.

```json
[
  { "at": "2026-06-04T00:38:49.470Z", "body": { "connector": "salesforce-go", "providerName": "basic", "config": { "username": "...", "password": "..." } } }
]
```

The real RDS will not have this endpoint.

## Stub policy (deterministic)

- Any value in `config` equal to literal `"FAIL"` → `{ success: false, message: "rejected by stub: a config value was \"FAIL\"" }`. Used to demo the failure UX.
- Missing `username` or `password` in `config` → `{ success: false, message: "rejected by stub: missing required credentials" }`.
- Otherwise → `{ success: true, message: "validated-by-stub-rds:<connector>:<providerName-or-default>" }`.

The marker `validated-by-stub-rds:...` is what proves the round-trip happened — same pattern as `RDS_MARKER` in [testConnection.integration.test.ts](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnection.integration.test.ts).
