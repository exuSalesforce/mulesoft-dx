# build-headless-integration — status

Last reviewed: 2026-06-04.

This document inventories what the skill does today, what it produces, and what still has to land before it matches the [`build-mule-integration`](../build-mule-integration/) skill at full parity. It's the reading order: start here when picking the skill back up.

## Goal in one sentence

Generate a versionless `.mule/project.json`-driven Mule integration project that:

1. Picks Go connectors live from RDS — `GET /v1/connectors` for the catalog, `GET /v1/connectors/{name}/descriptor` for each pick. The skill ships no local connector bundles.
2. Talks to RDS over plain HTTP for `test-connection` and connector metadata.
3. Produces a project with the same shape as `go-runtime/testdata/apps/salesforce-accounts-to-twilio` in the sibling go-runtime checkout.
4. Renders the flow inline in Claude Desktop and lets the user click "Test Connection" inside ACB.

## Current architecture

```
Claude Desktop
    └── build-headless-integration skill
          ├── $ACB_HOME/.cache/go/<name>/                              ← warm cache (cache-first)
          │     extension-model.json + dsl.json + extension.xsd          (default $ACB_HOME: $HOME/AnypointCodeBuilder)
          └── HTTP/JSON to the real Go RDS at MULE_DX_RDS_URL
                (default http://localhost:8090; brought up by ensure_rds.sh
                 which delegates to go-runtime/start-rds.sh)
                       └── ConnectivityService (gRPC :50051)
                              └── connector .wasm modules → real APIs
```

The skill targets the real RDS only — no stub backend. RDS reachability is enforced at Step 1.

Reference contracts (paths in the workspace; `mule-dx-mule-dev-component`, `go-runtime`, etc. are sibling checkouts):

- RDS HTTP: `mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/.../HttpRemoteDesignServiceClient.java`, Go server `go-runtime/dservicex/`
- Routing decision (Go vs Java): `mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/.../DesignConnectivityClientProvider.java`
- Live-stack test: `mule-dx-mule-dev-component/mule-dx-mule-dev-vscode/src/test-emulator/test/testConnectionRds.integration.test.ts`

## Done

### Skill scaffold

- [`SKILL.md`](SKILL.md) — entry point + 10-step workflow + workspace layout + bundled scripts table
- All scripts default to `WS_DIR=$HOME/Salesforce/projects/headless` (override via env)
- Two-phase Design → Build pattern with hard approval gate

### Phase 1 — Design

- [`scripts/validate_prerequisites.sh`](scripts/validate_prerequisites.sh) — Node 18+, jq, curl, ACB presence; auto-brings up RDS via `ensure_rds.sh` and hard-fails if RDS isn't reachable
- [`scripts/ensure_rds.sh`](scripts/ensure_rds.sh) — probe `MULE_DX_RDS_URL/healthz` (default `http://localhost:8090`), defer to `start_real_rds.sh` on miss. Idempotent.
- [`scripts/start_real_rds.sh`](scripts/start_real_rds.sh) — defers to `go-runtime/start-rds.sh`; preflight checks Docker + Go toolchain + data-weave sibling
- [`scripts/list_rds_connectors.sh`](scripts/list_rds_connectors.sh) — probe `GET /v1/connectors`, annotated with whether each is pickable (has `/descriptor`)
- [`scripts/search_connectors.sh`](scripts/search_connectors.sh) — query RDS `GET /v1/connectors`, filter by substring
- [`scripts/seed_cache.sh`](scripts/seed_cache.sh) — one-shot pre-warm of `$ACB_HOME/.cache/go/<name>/` from RDS so subsequent picks succeed offline
- [`scripts/pick_connector.sh`](scripts/pick_connector.sh) — record bundle name + prefix + namespace + schemaLocation
- [`scripts/describe_connector.sh`](scripts/describe_connector.sh) — generates rich digest + the build-mule-integration file family

### Phase 2 — Build

- [`scripts/commit_design_spec.sh`](scripts/commit_design_spec.sh) — merge picks into `tmp/design-spec.json`
- [`scripts/create_versionless_project.sh`](scripts/create_versionless_project.sh) — emits `project-manifest.json` (name-only, matches upgrade-to-versionless output), `.mule/project.json`, stub `pom.xml`, `mule-artifact.json`, dot-keyed `config.yaml` with env-var defaults. Pre-warms `$ACB_HOME/.cache/go/<name>/` so the ACB plugin's `ManifestRdsExtensionModelSource` renders the canvas without a fresh RDS fetch.
- [`scripts/validate_generated_flow_xml.sh`](scripts/validate_generated_flow_xml.sh) — five checks: schemaLocation pairs, known DSL elements, error types, `config-ref` resolution, `${...}` placeholder coverage

### Helpers

- [`helpers/digest_extension_model.mjs`](helpers/digest_extension_model.mjs) — Go bundle (`extension-model.json` + `dsl.json`) → Claude-readable digest; carries `defaultValue`, `allowedValues`, per-op `errorTypes`, DSL element names from `dsl.json`
- [`helpers/emit_metadata_files.mjs`](helpers/emit_metadata_files.mjs) — splits the rich digest into the build-mule-integration file shape (`<nick>.json` flat, `<nick>-<op>.json` per-op, `<nick>-config.json` per-config, `connector-errors/<nick>.json` + `<nick>.<op>.json`)
- [`helpers/validate_flow.mjs`](helpers/validate_flow.mjs) — backing implementation for `validate_generated_flow_xml.sh`

### References (docs)

- [`references/reference-flow-pattern.md`](references/reference-flow-pattern.md) — canonical flow skeleton + trigger variants (HTTP listener, scheduler, connector source) + Java-vs-Go connector form table + failure-mode rules. Sole input the agent reads when generating flow XML.
- [`references/rds-protocol.md`](references/rds-protocol.md) — RDS wire contract, mode selection, future endpoints

Three earlier docs were removed in 2026-06-05 cleanup (after observing `build-mule-integration` ships no flow templates either): `flow-templates/` (5 files — duplicated the skeleton already in `reference-flow-pattern.md`), `project-json-schema.md` (the script `create_versionless_project.sh` owns the format; the doc rotted when the script changed), `go-connector-catalog.md` (deprecated by `bash scripts/list_rds_connectors.sh`).

### Connectors live on RDS (current `connector-service/config.yaml`)

- `salesforce` — prefix `salesforce`, providers `basic` / `jwt` / `saml`
- `twilio` — prefix `twilio`, single provider `account-sid-auth-token`
- `http` — prefix `http`

The skill ships no local copies. `bash "$SKILL/scripts/list_rds_connectors.sh"` against a running RDS prints the live list.

### Verified end-to-end

A `salesforce-accounts-to-twilio-headless/` project under `$WS_DIR` produced from the skill, with:

- `project-manifest.json` carrying name-only connector list (matches what upgrade-to-versionless produces)
- `.mule/project.json` (workspace descriptor; no connector list — that moved to the manifest)
- Stub `pom.xml` mirroring the reference layout
- `$ACB_HOME/.cache/go/{salesforce,twilio}/` pre-warmed (the ACB plugin reads from this exact path)
- `mule-artifact.json` (minimal shape: `minMuleVersion` + `javaSpecificationVersions`)
- Dot-keyed `config.yaml` with env-var defaults for both connectors
- Multi-connector flow XML following the reference pattern
- `validate_generated_flow_xml.sh` clean
- Both `POST /v1/test-connection` round-trips against the real RDS returning success

## Pending

### Skill / client side

- **Live Exchange search** — `search_connectors.sh` only sees what RDS has loaded. To match the old skill's Exchange reach (every Maven connector ever published), fall back to Exchange REST or an RDS proxy when no local match. Lower priority.

- ~~**Bundles refresh**~~ — **DONE.** RDS owns the descriptors; [`scripts/fetch_bundle.sh`](scripts/fetch_bundle.sh) is cache-first then falls back to `GET /v1/connectors/<name>/descriptor`, write-through to `$ACB_HOME/.cache/go/<name>/`. The skill no longer ships bundle copies.

- **Trigger detection from connector sources** — Step 6 says "examine sources from the digest" but the agent has no helper. Could add a small `helpers/find_trigger_source.mjs` that takes a user phrase + a digest and returns matching source names ranked.

- **Operation child-element schema** — current digest models `parameterModels[]` as flat attributes. Connectors that genuinely need nested elements (`<db:my-sql-connection>` carrying `<db:connection-properties>`) won't render correctly. Affects DB / OAuth-callback flows. Not a problem for `salesforce`/`twilio`/`http` bundles today.

- **Validator: per-element attribute coverage** — `validate_generated_flow_xml.sh` checks element names, error types, config-refs, and `${...}` placeholders, but **not whether each `<prefix:element attrX=...>` uses an attribute name the descriptor's dsl.json declares for that element**. Real bug this missed (2026-06-05): the agent wrote `<salesforce:query salesforceQuery="...">` (Java-connector attribute name) when the Go connector's descriptor declared `soql`. ACB rendered it as an invalid attribute warning. Fix: add a 6th check that for every `<prefix:elementName>` in the flow XML, every attribute except `doc:*` / `xmlns:*` / `xsi:*` must appear in `dsl.json:operations[<name>].attributes` (or `connectionProviders[*]` / `configurations[*]`). Same lookup the canvas does on render.

- ~~**MCP flow renderer**~~ — **DONE (v1).** [`mcp/`](mcp/README.md) ships a standalone FastMCP server that exposes `render_mule_flow(project_dir)`. It parses the flow XML into a flat `{nodes, edges}` graph and returns a UI resource Claude Desktop iframes inline (React Flow + dagre, top-to-bottom layout, in-iframe side panel for node attributes). Step 10 in [`SKILL.md`](SKILL.md) now calls this tool. **v1 limitations** (deliberate): containers like `<choice>` / `<try>` / `<scatter-gather>` collapse to a single summary node — a real nested visualisation requires porting the layout engine from `mule-dx-mule-dev-vscode/src/views/xml-editor/` and is a v2 task. Read-only; no edit-from-canvas; no per-connector icons (generic kind badges).

### Java platform

None of the items below block Demo 2 — the stub `pom.xml` fallback covers them:

- `DefaultProjectDescriptor.java` (in `mule-dx-vscode/mule-dx-platform`) — add `muleVersion`, `javaVersion`, `dependencies`, `sharedLibraries`. Make `source` nullable. (Connectors are NOT a field here — they live in the sibling `project-manifest.json`, read by `ProjectManifest.java` in the `mule-dx-mule-dev-plugin`.)
- `DefaultProjectDescriptorBuilder.java` — builder methods for new fields.
- `WorkspaceManagerImpl.java` — branch on versionless: skip the pom.xml requirement when a sibling `project-manifest.json` is present.

When this lands the skill drops the stub `pom.xml` emit.

### RDS server side

Documented in [`references/rds-protocol.md`](references/rds-protocol.md):

- ✅ **`GET /v1/connectors/{name}/extension-model`** — implemented in `go-runtime/dservicex/internal/api/handler.go`. Backed by `internal/bundles/`, reads from `--bundles-dir` (default `/bundles` in the container; `../connectors:/bundles:ro` mounted via `deploy/docker-compose.yaml`). Smoke-tested against twilio/salesforce_v2/http.
- ✅ **`GET /v1/connectors/{name}/dsl`** — implemented same handler, same backing store.
- ⏳ **`GET /v1/exchange/search?q=`** — pending. Proxy to Anypoint Exchange for non-Go connectors. Lower priority because the static catalog plus live `/v1/connectors/{name}/extension-model` covers Demo 2.

### Real RDS environment prereqs (operator-side, not code)

Documented in [`scripts/start_real_rds.sh`](scripts/start_real_rds.sh). The skill detects + reports clearly when these are missing:

- Docker daemon running
- Go toolchain on `PATH` (1.26.3+) for the host-side `go mod vendor`
- `../data-weave/go` sibling checkout (private repo, branch `labs/dw-golang`)

There is no stub fallback — these are hard requirements.

## File index

```
build-headless-integration/
├── SKILL.md                                    main entry
├── STATUS.md                                   this file
├── scripts/                                    bash helpers (the agent invokes these)
│   ├── validate_prerequisites.sh               Step 1 — env probes + auto-bring-up of RDS
│   ├── ensure_rds.sh                           probe MULE_DX_RDS_URL/healthz; defer to ↓ on miss
│   ├── start_real_rds.sh                       real RDS via Docker + go-runtime/start-rds.sh
│   ├── list_rds_connectors.sh
│   ├── search_connectors.sh
│   ├── pick_connector.sh                       (resolves bundles via fetch_bundle.sh)
│   ├── fetch_bundle.sh                         (cache → RDS /descriptor)
│   ├── seed_cache.sh                           (one-shot pre-warm of ACB cache from RDS)
│   ├── describe_connector.sh
│   ├── commit_design_spec.sh
│   ├── create_versionless_project.sh
│   └── validate_generated_flow_xml.sh
├── helpers/                                    Node helpers (data only)
│   ├── digest_extension_model.mjs
│   ├── emit_metadata_files.mjs
│   └── validate_flow.mjs
├── references/                                 docs the agent reads
│   ├── reference-flow-pattern.md               flow skeleton + trigger variants + rules
│   └── rds-protocol.md                         RDS wire contract (operator-facing)
└── mcp/                                        Step 10 flow-render MCP server (FastMCP + React Flow)
    ├── README.md                               install + claude_desktop_config.json snippet
    ├── pyproject.toml                          Python 3.11+, mcp[cli], lxml; console_script entry
    ├── build_headless_integration_mcp/
    │   ├── server.py                           FastMCP entry; render_mule_flow tool + UI resource
    │   ├── parse.py                            Mule XML → {nodes, edges} (flat tree)
    │   └── ui/                                 bundled iframe HTML (React + ReactFlow + dagre)
    │       ├── app.html
    │       ├── app.css
    │       └── app.js
    └── tests/
        ├── test_parse.py                       8 behavioural tests against real fixtures
        └── fixtures/                           sf-to-twilio.xml, scheduler-flow.xml, choice-flow.xml
```

## Running the real RDS stack (full bring-up)

The skill targets the real RDS only; it brings RDS + ConnectivityService up via Docker Compose with real WASM connector binaries (no stub fallback).

### One-time prereqs

```bash
# 1. Go toolchain (host-side `go mod vendor` is required before docker compose builds).
brew install go        # 1.26.3+

# 2. The replace'd sibling module — DataWeave Go engine.
cd "$HOME/Salesforce/workspace"
git clone -b labs/dw-golang git@github_emu:mulesoft-emu/data-weave.git data-weave

# 3. Docker Desktop running.
docker info >/dev/null
```

`go-runtime`'s `go.work.example` shows the expected layout:

```
$HOME/Salesforce/workspace/
├── go-runtime/        ← this repo (branch: labs/rds)
└── data-weave/        ← DataWeave Go engine (branch: labs/dw-golang)
    └── go/            ← module pulled in via `replace github.com/mulesoft/data-weave/go => ../data-weave/go`
```

### Start

The skill brings RDS up automatically via `validate_prerequisites.sh` → `ensure_rds.sh` → `start_real_rds.sh` if it isn't already reachable. To bring it up directly (e.g. before launching ACB without running the skill):

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"

PATH=/opt/homebrew/bin:$PATH \
  GO_RUNTIME="$HOME/Salesforce/workspace/go-runtime" \
  "$SKILL/scripts/start_real_rds.sh"
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
curl -sS  http://localhost:8090/v1/connectors/twilio/descriptor        # all three artifacts
```

Tell ACB about it:

```bash
export MULE_DX_RDS_MODE=dev
export MULE_DX_RDS_URL=http://localhost:8090
```

### Stop

```bash
"$SKILL/scripts/start_real_rds.sh" down
```

### Subsequent starts

`go mod vendor` and the WASM build are skipped when the artifacts are already present. Re-run with `--rebuild` if connector source changes:

```bash
PATH=/opt/homebrew/bin:$PATH \
  GO_RUNTIME="$HOME/Salesforce/workspace/go-runtime" \
  "$SKILL/scripts/start_real_rds.sh" --rebuild
```

## How to run the skill end-to-end (smoke test)

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"
WS_DIR="$HOME/Salesforce/projects/headless"   # default; override with WS_DIR=...

# Phase 1
"$SKILL/scripts/validate_prerequisites.sh"   # auto-brings up RDS if needed; hard-fails on miss
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

PROJECT="$WS_DIR/smoke-demo"
"$SKILL/scripts/create_versionless_project.sh" "$PROJECT"
# (the agent writes $PROJECT/src/main/mule/<name>.xml from the digest)
"$SKILL/scripts/validate_generated_flow_xml.sh" "$PROJECT"
# Step 10 (visualization) is currently a no-op pending the MCP flow-render tool.
```

Open `$PROJECT/` in ACB. Test Connection on the connector configs hits the running RDS at `MULE_DX_RDS_URL`.
