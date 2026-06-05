# Go-connector catalog

The skill no longer ships local connector bundles. The live catalog is whatever RDS reports via `GET /v1/connectors` — derived from [`connector-service/config.yaml`](file:///Users/tzeree/Salesforce/workspace/go-runtime/services/connector-service/config.yaml) on the running stack.

## Live query

```bash
bash scripts/list_rds_connectors.sh
# → { "connectors": [ { "name": "...", "operations": [...] }, ... ] }
```

`search_connectors.sh <term>` filters that list by substring on the name.

## What ships in the running stack today

The default `connector-service/config.yaml` registers three connectors. Their providers (from `extension-model.json`):

| Name | Prefix (XML) | Config element | Connection providers |
| --- | --- | --- | --- |
| `salesforce` | `salesforce` | `salesforce:sfdc-config` | `basic`, `jwt`, `saml` |
| `twilio` | `twilio` | `twilio:config` | `account-sid-auth-token` |
| `http` | `http` | `http:request-config` (request side); `http:listener-config` (listener side, in core) | `http:request-connection` |

These are derived at runtime — re-confirm against the live RDS for any new connector before generating a flow.

## Adding a new connector

This is **not a skill-side concern**. To add a connector to the catalog:

1. Build the connector module + descriptor under `go-runtime/connectors/<name>/`.
2. Add it to `services/connector-service/config.yaml` with `module:` (path to .wasm) and `descriptor_dir:` (path to its descriptor folder).
3. Mount the descriptor folder into `connector-service` via `deploy/docker-compose.yaml`.
4. Restart the stack (`./start-rds.sh --rebuild`).

Once the connector shows up in `list_rds_connectors.sh`, the skill discovers it automatically — no skill change needed.

## Drift watch

The descriptor source on the plugin side is [`ManifestRdsExtensionModelSource`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/ManifestRdsExtensionModelSource.java). It reads `project-manifest.json`, then for each connector name resolves cache-first under `~/AnypointCodeBuilder/.cache/go/<name>/`, falling back to `GET /v1/connectors/{name}/descriptor`. The skill mirrors this exactly via `fetch_bundle.sh`. If file names or directory layout change on the plugin side, follow.
