# build-headless-integration — status

Last reviewed: 2026-06-04.

This document inventories what the skill does today, what it produces, and what still has to land before it matches the [`build-mule-integration`](../build-mule-integration/) skill at full parity. It's the reading order: start here when picking the skill back up.

## Goal in one sentence

Generate a versionless ([`.mule/project.json`](references/project-json-schema.md))-driven Mule integration project that:

1. Picks Go connectors live from RDS — `GET /v1/connectors` for the catalog, `GET /v1/connectors/{name}/descriptor` for each pick. The skill ships no local connector bundles.
2. Talks to RDS over plain HTTP for `test-connection` and connector metadata.
3. Produces a project with the same shape as [`go-runtime/testdata/apps/salesforce-accounts-to-twilio`](file:///Users/tzeree/Salesforce/workspace/go-runtime/testdata/apps/salesforce-accounts-to-twilio).
4. Renders the flow inline in Claude Desktop and lets the user click "Test Connection" inside ACB.

## Current architecture

```
Claude Desktop
    └── build-headless-integration skill
          ├── ~/AnypointCodeBuilder/.cache/go/<name>/                 ← warm cache (cache-first)
          │     extension-model.json + dsl.json + extension.xsd
          └── HTTP/JSON to RDS
                ├── stub: helpers/rds_stub.mjs                        ← default backend
                └── real: go-runtime/start-rds.sh                     ← Docker, real binaries
                       └── ConnectivityService (gRPC :50051)
                              └── connector .wasm modules → real APIs
```

Reference contracts:

- RDS HTTP: [`HttpRemoteDesignServiceClient.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/HttpRemoteDesignServiceClient.java), Go server [`dservicex/`](file:///Users/tzeree/Salesforce/workspace/go-runtime/dservicex/)
- Routing decision (Go vs Java): [`DesignConnectivityClientProvider.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/connectivity/DesignConnectivityClientProvider.java)
- Wire-faithful stub pattern: [`testConnection.integration.test.ts`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnection.integration.test.ts) lines 110–148
- Live-stack test: [`testConnectionRds.integration.test.ts`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnectionRds.integration.test.ts)

## Done

### Skill scaffold

- [`SKILL.md`](SKILL.md) — entry point + 10-step workflow + workspace layout + bundled scripts table
- All scripts default to `WS_DIR=$HOME/Salesforce/projects/headless` (override via env)
- Two-phase Design → Build pattern with hard approval gate

### Phase 1 — Design

- [`scripts/validate_prerequisites.sh`](scripts/validate_prerequisites.sh) — Node 18+, jq, curl, ACB presence (no anypoint-cli, no Java JAR check)
- [`scripts/start_rds_stub.sh [--real]`](scripts/start_rds_stub.sh) — three backends (stub / external / real), backend-mismatch detection, idempotent
- [`scripts/start_real_rds.sh`](scripts/start_real_rds.sh) — defers to [`go-runtime/start-rds.sh`](file:///Users/tzeree/Salesforce/workspace/go-runtime/start-rds.sh); preflight checks Docker + Go toolchain + data-weave sibling
- [`scripts/stop_rds_stub.sh`](scripts/stop_rds_stub.sh) — clean SIGTERM; no-op on external/real backends
- [`scripts/list_rds_connectors.sh`](scripts/list_rds_connectors.sh) — probe `GET /v1/connectors`; stub returns 404 (handled gracefully)
- [`scripts/search_connectors.sh`](scripts/search_connectors.sh) — query RDS `GET /v1/connectors`, filter by substring
- [`scripts/seed_cache.sh`](scripts/seed_cache.sh) — one-shot pre-warm of `~/AnypointCodeBuilder/.cache/go/<name>/` from RDS so subsequent picks succeed offline
- [`scripts/pick_connector.sh`](scripts/pick_connector.sh) — record bundle name + prefix + namespace + schemaLocation
- [`scripts/describe_connector.sh`](scripts/describe_connector.sh) — generates rich digest + the build-mule-integration file family

### Phase 2 — Build

- [`scripts/commit_design_spec.sh`](scripts/commit_design_spec.sh) — merge picks into `tmp/design-spec.json`
- [`scripts/create_versionless_project.sh`](scripts/create_versionless_project.sh) — emits `project-manifest.json` (name-only, matches upgrade-to-versionless output), `.mule/project.json`, stub `pom.xml`, `mule-artifact.json`, dot-keyed `config.yaml` with env-var defaults + `# allowed: ...` / `# default: ...` comments. Pre-warms `~/AnypointCodeBuilder/.cache/go/<name>/` so the ACB plugin's [ManifestRdsExtensionModelSource](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/ManifestRdsExtensionModelSource.java) renders the canvas without a fresh RDS fetch.
- [`scripts/validate_generated_flow_xml.sh`](scripts/validate_generated_flow_xml.sh) — five checks: schemaLocation pairs, known DSL elements, error types, `config-ref` resolution, `${...}` placeholder coverage
- ~~`scripts/visualize_flow.sh`~~ — removed; an MCP flow-render tool will own visualization (see "Pending → MCP flow renderer")

### Helpers

- [`helpers/digest_extension_model.mjs`](helpers/digest_extension_model.mjs) — Go bundle (`extension-model.json` + `dsl.json`) → Claude-readable digest; carries `defaultValue`, `allowedValues`, per-op `errorTypes`, DSL element names from `dsl.json`
- [`helpers/emit_metadata_files.mjs`](helpers/emit_metadata_files.mjs) — splits the rich digest into the build-mule-integration file shape (`<nick>.json` flat, `<nick>-<op>.json` per-op, `<nick>-config.json` per-config, `connector-errors/<nick>.json` + `<nick>.<op>.json`)
- [`helpers/rds_stub.mjs`](helpers/rds_stub.mjs) — wire-faithful Node stub (`/healthz`, `POST /v1/test-connection`, deterministic policy, `/_requests` debug)
- [`helpers/validate_flow.mjs`](helpers/validate_flow.mjs) — backing implementation for `validate_generated_flow_xml.sh`

### References (docs)

- [`references/reference-flow-pattern.md`](references/reference-flow-pattern.md) — canonical flow shape modeled on `salesforce-accounts-to-twilio.xml`
- [`references/flow-templates/`](references/flow-templates/) — concrete starting points: `scheduler.xml`, `http-listener.xml`, `connector-source.xml`, `multi-connector-http.xml`, `README.md` (token guide)
- [`references/project-json-schema.md`](references/project-json-schema.md) — `.mule/project.json` shape + Java platform follow-up needed
- [`references/rds-protocol.md`](references/rds-protocol.md) — RDS wire contract, mode selection, future endpoints
- [`references/go-connector-catalog.md`](references/go-connector-catalog.md) — note: live catalog is now `bash scripts/list_rds_connectors.sh`; this doc is a static reference of what RDS typically ships

### Connectors live on RDS (current `connector-service/config.yaml`)

- `salesforce` — prefix `salesforce`, providers `basic` / `jwt` / `saml`
- `twilio` — prefix `twilio`, single provider `account-sid-auth-token`
- `http` — prefix `http`

The skill ships no local copies. `bash scripts/list_rds_connectors.sh` against a running RDS prints the live list.

### Verified end-to-end

`~/Salesforce/projects/headless/salesforce-accounts-to-twilio-headless/` produced from the skill, with:

- `project-manifest.json` carrying name-only connector list (matches what upgrade-to-versionless produces)
- `.mule/project.json` (workspace descriptor; no connector list — that moved to the manifest)
- Stub `pom.xml` mirroring the reference layout
- `~/AnypointCodeBuilder/.cache/go/{salesforce,twilio}/` pre-warmed (the ACB plugin reads from this exact path)
- `mule-artifact.json` (minimal shape: `minMuleVersion` + `javaSpecificationVersions`)
- Dot-keyed `config.yaml` with env-var defaults for both connectors
- Multi-connector flow XML following the reference pattern
- `validate_generated_flow_xml.sh` clean
- Both `POST /v1/test-connection` round-trips against the stub returning the marker

## Pending

### Skill / client side

- **Live Exchange search** — `search_connectors.sh` only sees what RDS has loaded. To match the old skill's Exchange reach (every Maven connector ever published), fall back to Exchange REST or an RDS proxy when no local match. Lower priority.

- ~~**Bundles refresh**~~ — **DONE.** RDS owns the descriptors; [`scripts/fetch_bundle.sh`](scripts/fetch_bundle.sh) is cache-first then falls back to `GET /v1/connectors/<name>/descriptor`, write-through to `~/AnypointCodeBuilder/.cache/go/<name>/`. The skill no longer ships bundle copies.

- **Trigger detection from connector sources** — Step 6 says "examine sources from the digest" but the agent has no helper. Could add a small `helpers/find_trigger_source.mjs` that takes a user phrase + a digest and returns matching source names ranked.

- **Operation child-element schema** — current digest models `parameterModels[]` as flat attributes. Connectors that genuinely need nested elements (`<db:my-sql-connection>` carrying `<db:connection-properties>`) won't render correctly. Affects DB / OAuth-callback flows. Not a problem for `salesforce`/`twilio`/`http` bundles today.

- **MCP flow renderer** — Step 10 in [`SKILL.md`](SKILL.md) is a no-op placeholder. A separate MCP tool will render the canvas inline in Claude Desktop using the same renderer ACB ships (see [`mule-dx-mule-dev-vscode/src/views/xml-editor/`](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/views/xml-editor/) for what to reuse). Removed the previous SVG/PNG rasterizer (`scripts/visualize_flow.sh` + `helpers/visualize.mjs` + `@resvg/resvg-js`) — it produced thumbnail-quality boxes that the real MCP renderer will obsolete on day one. When the MCP tool ships, Step 10 becomes a single tool call against the just-written `src/main/mule/<projectName>.xml`.

### Java platform

These are tracked in [`references/project-json-schema.md`](references/project-json-schema.md) — none block Demo 2 because of the stub `pom.xml` fallback:

- [`DefaultProjectDescriptor.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptor.java) — add `muleVersion`, `javaVersion`, `dependencies`, `sharedLibraries`. Make `source` nullable. (Connectors are NOT a field here — they live in the sibling `project-manifest.json`, read by [ProjectManifest.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/project/ProjectManifest.java).)
- [`DefaultProjectDescriptorBuilder.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/api/impl/DefaultProjectDescriptorBuilder.java) — builder methods for new fields.
- [`WorkspaceManagerImpl.java`](file:///Users/tzeree/Salesforce/workspace/mule-dx-vscode/mule-dx-platform/src/main/java/org/mule/dx/platform/internal/WorkspaceManagerImpl.java) — branch on versionless: skip the pom.xml requirement when a sibling `project-manifest.json` is present.

When this lands the skill drops the stub `pom.xml` emit.

### RDS server side

Documented in [`references/rds-protocol.md`](references/rds-protocol.md):

- ✅ **`GET /v1/connectors/{name}/extension-model`** — implemented in [`go-runtime/dservicex/internal/api/handler.go`](file:///Users/tzeree/Salesforce/workspace/go-runtime/dservicex/internal/api/handler.go) (this iteration). Backed by [`internal/bundles/`](file:///Users/tzeree/Salesforce/workspace/go-runtime/dservicex/internal/bundles/), reads from `--bundles-dir` (default `/bundles` in the container; `../connectors:/bundles:ro` mounted via [`deploy/docker-compose.yaml`](file:///Users/tzeree/Salesforce/workspace/go-runtime/deploy/docker-compose.yaml)). Smoke-tested against twilio/salesforce_v2/http.
- ✅ **`GET /v1/connectors/{name}/dsl`** — implemented same handler, same backing store.
- ⏳ **`GET /v1/exchange/search?q=`** — pending. Proxy to Anypoint Exchange for non-Go connectors. Lower priority because the static catalog plus live `/v1/connectors/{name}/extension-model` covers Demo 2.

### Real RDS environment prereqs (operator-side, not code)

Documented in [`scripts/start_real_rds.sh`](scripts/start_real_rds.sh). The skill detects + reports clearly when these are missing:

- Docker daemon running
- Go toolchain on `PATH` (1.26.3+) for the host-side `go mod vendor`
- `../data-weave/go` sibling checkout (private repo, branch `labs/dw-golang`)

The local Node stub bypasses all three.

## File index

```
build-headless-integration/
├── SKILL.md                                    main entry
├── STATUS.md                                   this file
├── scripts/                                    bash helpers (the agent invokes these)
│   ├── validate_prerequisites.sh
│   ├── start_rds_stub.sh                       (default: stub) | --real defers to ↓
│   ├── start_real_rds.sh                       (real RDS via Docker + go-runtime/start-rds.sh)
│   ├── stop_rds_stub.sh
│   ├── list_rds_connectors.sh
│   ├── search_connectors.sh
│   ├── pick_connector.sh                       (resolves bundles via fetch_bundle.sh)
│   ├── fetch_bundle.sh                         (cache → RDS /descriptor)
│   ├── seed_cache.sh                           (one-shot pre-warm of ACB cache from RDS)
│   ├── describe_connector.sh
│   ├── commit_design_spec.sh
│   ├── create_versionless_project.sh
│   ├── validate_generated_flow_xml.sh
├── helpers/                                    Node helpers (data only)
│   ├── digest_extension_model.mjs
│   ├── emit_metadata_files.mjs
│   ├── rds_stub.mjs
│   └── validate_flow.mjs
└── references/                                 docs the agent reads
    ├── reference-flow-pattern.md
    ├── project-json-schema.md
    ├── rds-protocol.md
    ├── go-connector-catalog.md
    └── flow-templates/
        ├── README.md                           token substitution guide
        ├── scheduler.xml
        ├── http-listener.xml
        ├── connector-source.xml
        └── multi-connector-http.xml
```

## Running the real RDS stack (full bring-up)

The skill works against three backends (see [`references/rds-protocol.md`](references/rds-protocol.md)). The default Node stub answers `/healthz` + `POST /v1/test-connection` deterministically and needs no Docker. The **real stack** (recommended for verifying connector behavior end-to-end) brings up RDS + ConnectivityService via Docker Compose with real WASM connector binaries.

### One-time prereqs

```bash
# 1. Go toolchain (host-side `go mod vendor` is required before docker compose builds).
brew install go        # 1.26.3+

# 2. The replace'd sibling module — DataWeave Go engine.
cd ~/Salesforce/workspace
git clone -b labs/dw-golang git@github_emu:mulesoft-emu/data-weave.git data-weave

# 3. Docker Desktop running.
docker info >/dev/null
```

`go-runtime`'s [`go.work.example`](file:///Users/tzeree/Salesforce/workspace/go-runtime/go.work.example) shows the expected layout:

```
~/Salesforce/workspace/
├── go-runtime/        ← this repo (branch: labs/rds)
└── data-weave/        ← DataWeave Go engine (branch: labs/dw-golang)
    └── go/            ← module pulled in via `replace github.com/mulesoft/data-weave/go => ../data-weave/go`
```

### Start

```bash
SKILL=~/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration

PATH=/opt/homebrew/bin:$PATH \
  GO_RUNTIME=~/Salesforce/workspace/go-runtime \
  "$SKILL/scripts/start_real_rds.sh"
```

Or pass `--real` to the regular start script (it defers to `start_real_rds.sh`):

```bash
PATH=/opt/homebrew/bin:$PATH \
  GO_RUNTIME=~/Salesforce/workspace/go-runtime \
  "$SKILL/scripts/start_rds_stub.sh" --real
```

What `start-rds.sh` does on first run:
1. `go mod vendor` (vendors the data-weave/go sibling).
2. `./deploy/build-wasm-modules.sh` (compiles `salesforce.wasm`, `http.wasm`, `twilio.wasm` to `services/connector-service/modules/`).
3. `docker compose -f docker-compose.yaml up -d --build rds connector-service`.
4. Polls `http://localhost:8090/healthz` until ready.

After it prints `RDS is healthy at http://localhost:8090`:

```bash
curl -fsS http://localhost:8090/healthz
curl -sS  http://localhost:8090/v1/connectors                          # loaded modules
curl -sS  http://localhost:8090/v1/connectors/twilio/extension-model   # 2.6 MB JSON
curl -sS  http://localhost:8090/v1/connectors/twilio/dsl               # 800 KB JSON
```

Tell ACB about it:

```bash
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://localhost:8090
```

### Stop

```bash
"$SKILL/scripts/start_real_rds.sh" down
# or:
docker compose -f ~/Salesforce/workspace/go-runtime/deploy/docker-compose.yaml down
```

### Subsequent starts

`go mod vendor` and the WASM build are skipped when the artifacts are already present. Re-run with `--rebuild` if connector source changes:

```bash
PATH=/opt/homebrew/bin:$PATH GO_RUNTIME=~/Salesforce/workspace/go-runtime \
  "$SKILL/scripts/start_real_rds.sh" --rebuild
```

### Persistent PATH (optional)

If you want `go` on PATH for every shell:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
```

(The skill's `start_real_rds.sh` invocations always set PATH explicitly so this isn't required for the skill itself.)

## How to run the skill end-to-end (smoke test)

```bash
SKILL=~/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration

# Phase 1
"$SKILL/scripts/validate_prerequisites.sh"
"$SKILL/scripts/start_rds_stub.sh"                     # stub backend
"$SKILL/scripts/pick_connector.sh" sfdc salesforce
"$SKILL/scripts/pick_connector.sh" twilio twilio
"$SKILL/scripts/describe_connector.sh" sfdc
"$SKILL/scripts/describe_connector.sh" twilio

# Phase 2
echo '{
  "projectName":"smoke-demo","muleVersion":"4.11.2","javaVersion":"17",
  "trigger":{"kind":"http-listener","path":"/ops/notify"},
  "connections":[
    {"nick":"sfdc","configName":"salesforceConfig","providerName":"basic"},
    {"nick":"twilio","configName":"twilioConfig","providerName":"account-sid-auth-token"}
  ]
}' | "$SKILL/scripts/commit_design_spec.sh"

PROJECT=~/Salesforce/projects/headless/smoke-demo
"$SKILL/scripts/create_versionless_project.sh" "$PROJECT"
# (the agent writes $PROJECT/src/main/mule/<name>.xml from a flow template)
"$SKILL/scripts/validate_generated_flow_xml.sh" "$PROJECT"
# Step 10 (visualization) is currently a no-op pending the MCP flow-render tool.
"$SKILL/scripts/stop_rds_stub.sh"
```

For the real RDS path, replace `start_rds_stub.sh` with `start_rds_stub.sh --real` (everything else is identical).
