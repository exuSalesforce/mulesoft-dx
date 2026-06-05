---
name: build-headless-integration
description: Workflow for building a versionless (headless) Mule integration project that targets Go-based connectors via the Remote Design Service (RDS). Use when the user asks to create, generate, or build a "headless", "versionless", "Go-connector", or "no-pom" Mule integration; or when they explicitly opt into the design-service / RDS path. For traditional Maven-based Mule projects use `build-mule-integration` instead. Triggers include "headless integration", "go connector", "salesforce-go", "design service", or "RDS test connection".
license: Apache-2.0
compatibility: Requires Node.js 18+, jq, curl, ACB (for opening the generated project). Does NOT require anypoint-cli-v4, Maven, or Java; the legacy Java MTF design service is bypassed entirely.
metadata:
  author: mule-dx-tooling
  version: "0.1.0"
  cli: none
  backend: rds
  theme: professional
allowed-tools: Bash Read Write Edit AskUserQuestion
---

# Build Headless Integration

Build a versionless Go-connector Mule integration via the Remote Design Service (RDS), with no Maven, no anypoint-cli-v4, and no MTF.

## When to Use This Skill

**Use this skill when users request:**

- "Create a headless Mule integration / project"
- "Build a versionless Mule app"
- "Use go-connectors / salesforce-go"
- "Use the design service / RDS for test-connection"
- "Generate a project I can open in ACB and click Test Connection"
- "Build a Mule project without a pom.xml"

**Do NOT use this skill when:**

- The user wants a traditional Maven-based Mule project (use `build-mule-integration`).
- The user names a connector that doesn't have a Go bundle yet — see `references/go-connector-catalog.md` for the current inventory.

If the right path is ambiguous, ask the user once with `AskUserQuestion`: "Headless / RDS path, or traditional Maven path?"

---

## Architecture (one paragraph)

Connector descriptors come from RDS by name — `GET /v1/connectors/{name}/descriptor` returns the three artifacts (`extension-model.json`, `dsl.json`, `extension.xsd`) atomically. The skill writes them through to `~/AnypointCodeBuilder/.cache/go/<name>/`, the same warm cache the ACB plugin's [ManifestRdsExtensionModelSource](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/extension/json/ManifestRdsExtensionModelSource.java) reads on project-open. A local `fixtures/go-connectors/<name>/` lookup short-circuits the network call when present (offline). Test-connection still goes through `POST /v1/test-connection`, the wire contract enforced by [HttpRemoteDesignServiceClient.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/designservice/rds/HttpRemoteDesignServiceClient.java). The project the skill produces matches the shape that the upgrade-to-versionless flow ([DefaultProjectPropertiesService.java](file:///Users/tzeree/Salesforce/workspace/mule-dx-mule-dev-component/mule-dx-mule-dev-plugin/src/main/java/org/mule/contribution/internal/project/DefaultProjectPropertiesService.java)) writes when migrating an existing Maven project: `project-manifest.json` (sibling of `pom.xml`, name-only connector list) plus a stub `pom.xml` so today's `WorkspaceManagerImpl` can still open the project.

---

## Prerequisites

```bash
node --version          # 18+
jq --version
curl --version
ls ~/AnypointCodeBuilder
```

Step 1 checks all of the above and writes `$WS_DIR/tmp/headless-env.json`. Stop if it exits non-zero.

---

## Workspace layout

All scripts share the same workspace root, controlled by the `WS_DIR` env var. **Default: `~/Salesforce/projects/headless`** — set explicitly by the script defaults so the skill never scribbles wherever the agent's `$PWD` happens to point.

Layout under `WS_DIR`:

```
~/Salesforce/projects/headless/
├── tmp/                                          # scratch (Phase 1 state, RDS stub state, flow viz)
│   ├── headless-env.json
│   ├── rds.json, rds-stub.{pid,port,log}
│   ├── connector-choices/<nick>.json             # picked bundle reference
│   ├── connector-metadata/
│   │   ├── <nick>-digest.json                    # rich digest (this skill's internal SoT)
│   │   ├── <nick>.json                           # flat reference (operations/sources/configs/errorTypes)
│   │   ├── <nick>-<op>.json                      # per-operation deep metadata (one per op/source)
│   │   └── <nick>-config.json                    # per-config + connection-provider attributes
│   ├── connector-errors/
│   │   ├── <nick>.json                           # connector-wide errorTypes whitelist
│   │   └── <nick>.<op>.json                      # per-operation errorTypes
│   └── design-spec.json
└── <projectName>/                                # the generated Mule project (open this in ACB)
    ├── .mule/project.json
    ├── project-manifest.json                     # name-only connector list (matches upgrade-to-versionless output)
    ├── mule-artifact.json
    ├── pom.xml                                   # stub; goes away when WorkspaceManagerImpl supports no-pom
    └── src/main/{mule,resources}/...

~/AnypointCodeBuilder/.cache/go/<name>/           # warm cache (extension-model + dsl + xsd)
                                                  # populated by fetch_bundle.sh; read on project-open by
                                                  # ManifestRdsExtensionModelSource (no per-project bundles)
```

The split-file shape under `connector-metadata/` and `connector-errors/` mirrors what
[build-mule-integration's tmp/](file:///Users/tzeree/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-mule-integration) produces — any tool that reads either skill's tmp/ shape works against ours too.

Override per session if needed: `WS_DIR=/some/other/path bash scripts/<name>.sh`. All scripts honor it. `ACB_HOME` overrides the cache root (default `~/AnypointCodeBuilder`).

The user opens `$WS_DIR/<projectName>/` in ACB after Step 10 — never `tmp/`. ACB then reads `project-manifest.json`, sees connector names, hits the warm `~/AnypointCodeBuilder/.cache/go/<name>/` for descriptors, and the canvas renders.

---

## Bundled scripts

Invoke each script with the `Bash` tool. State persists under `$WS_DIR/tmp/` so later steps can read it mechanically.

| Script | Purpose | Output |
| --- | --- | --- |
| `scripts/validate_prerequisites.sh` | Step 1 — Node, jq, curl, ACB presence | `tmp/headless-env.json` |
| `scripts/start_rds_stub.sh [--real]` | Step 2 — ensure an RDS endpoint answers `/healthz`. Three backends, picked in order: (1) `--real` / `MULE_DX_USE_REAL_RDS=1` → defer to `start_real_rds.sh` (real Go RDS via Docker); (2) `MULE_DX_RDS_URL` set externally → trust it; (3) default → spawn `helpers/rds_stub.mjs`. Idempotent. | `tmp/rds.json` (`{url, managed, pid, backend}`) |
| `scripts/start_real_rds.sh [--rebuild\|down]` | Bring up the real RDS + ConnectivityService stack via `go-runtime/start-rds.sh`. Requires Docker + a `go-runtime` checkout (default `~/Salesforce/workspace/go-runtime`; override via `GO_RUNTIME`). | `tmp/rds.json` (`backend: "real"`) |
| `scripts/stop_rds_stub.sh` | Cleanup — stops the local stub if we managed it. No-op for external/real backends. | — |
| `scripts/list_rds_connectors.sh` | Probe `GET /v1/connectors` — list which connector binaries the running ConnectivityService has loaded. Real RDS only; stub returns 404 (handled gracefully). | stdout JSON |
| `scripts/search_connectors.sh <term>` | Step 4 — list bundles matching a term (`name`, `prefix`, or directory) from `fixtures/go-connectors/`. Format: `<bundle>\t<name>\t<version>\t<vendor>\t<prefix>` per line. | stdout |
| `scripts/pick_connector.sh <nick> <bundle>` | Step 4 — record the picked Go connector (resolves prefix, namespace, schemaLocation). Bundle resolution goes through `fetch_bundle.sh` (cache → fixture → RDS `/descriptor`). | `tmp/connector-choices/<nick>.json` |
| `scripts/fetch_bundle.sh <name>` | Resolve a connector bundle to a directory. Tries `~/AnypointCodeBuilder/.cache/go/<name>/` (the same warm cache the ACB plugin reads on project-open), then `fixtures/go-connectors/<name>/`, then `GET /v1/connectors/<name>/descriptor` (atomic 3-in-1 response) with write-through to the cache. Used by `pick_connector.sh`. Stub backend returns 404 here; only the real Go RDS implements `/descriptor`. | resolved bundle dir on stdout |
| `scripts/describe_connector.sh <nick>` | Step 5 — generate the rich digest + split it into the per-shape file family build-mule-integration produces (flat reference, per-op metadata, per-config metadata, error whitelists). Stdout lists each operation/source/provider with its **DSL element name** (sourced from the bundle's `dsl.json`) and required-param set. | `tmp/connector-metadata/<nick>-digest.json` (rich), `tmp/connector-metadata/<nick>.json` (flat reference), `tmp/connector-metadata/<nick>-<op>.json` (per-op), `tmp/connector-metadata/<nick>-config.json` (per-config), `tmp/connector-errors/<nick>.json` + `<nick>.<op>.json` |
| `scripts/commit_design_spec.sh` | Step 9 — read agent-supplied design spec on stdin; merge picks into `tmp/design-spec.json` | `tmp/design-spec.json` |
| `scripts/create_versionless_project.sh <projectDir>` | Step 9 — write `.mule/project.json`, `project-manifest.json`, stub `pom.xml`, `mule-artifact.json`, dot-keyed `config.yaml`. No bundles inside the project — they live in the warm cache (`~/AnypointCodeBuilder/.cache/go/<name>/`), pre-warmed during this step. | project on disk + cache pre-warmed |
| `scripts/validate_generated_flow_xml.sh <projectDir>` | Step 9.5 — validate the generated flow XML against the connector digests: schemaLocation pairs, known DSL element names, error types in `<on-error-propagate>`, `config-ref` resolution, `${...}` placeholders matching `config.yaml` keys. Cheap analogue of `validate_before_build.sh` from the build-mule-integration skill. | exit 0 on success; non-zero with stderr report on failure |

The agent generates the flow XML inline at Step 9 — bash does not call an LLM. The connector digest in `tmp/connector-metadata/<nick>.json` is the input.

Always invoke scripts via the absolute skill directory path supplied in the "skill is now active" message — never relative paths.

---

## Workflow shape (two phases)

This workflow has two phases separated by a hard user-approval gate.

- **Phase 1: Design (Steps 1–8).** Validate prereqs, ensure RDS is reachable, identify systems, pick + describe connectors, propose a trigger and connection providers, present the Technical Design Summary, wait for approval. Phase 1 writes only to `tmp/`.
- **Phase 2: Build (Steps 9–10).** Materialize the project, generate the flow XML, render the visualization. Phase 2 is the only phase that touches the user's project directory.

Phase 2 MUST NOT start until Step 8's approval gate passes explicitly.

## Workflow-wide discipline (read before Phase 1)

- **One bash invocation per response when it has side effects.** `start_rds_stub.sh`, `commit_design_spec.sh`, and `create_versionless_project.sh` each run alone.
- **Connector picks come from the static catalog only.** Demo 2 ships with the bundles under `fixtures/go-connectors/`; never invent a bundle name. If `search_connectors.sh` returns zero matches, tell the user that connector isn't available on the headless path yet — do not silently fall back to a different connector or to HTTP.
- **The flow XML is the agent's responsibility.** Read the digest from `tmp/connector-metadata/<nick>.json`, then write `<projectDir>/src/main/mule/<projectName>.xml` directly with the `Write` tool. Use the prefix and namespace recorded in the digest. Do not invent operation names or required parameters — they're listed in the digest.
- **No anypoint-cli-v4 calls.** This skill never shells out to it. If you find yourself reaching for `anypoint-cli-v4 dx`, you're on the wrong skill — switch to `build-mule-integration`.

---

# Phase 1: Design

## Step 1: Validate Prerequisites

```bash
bash scripts/validate_prerequisites.sh
```

If the exit code is non-zero, STOP and surface `tmp/headless-env.json:.errors[]` to the user. Do not proceed.

## Step 2: Ensure RDS is reachable

```bash
bash scripts/start_rds_stub.sh             # default: local Node stub
# or:
bash scripts/start_rds_stub.sh --real      # real Go RDS via Docker (requires go-runtime checkout)
```

The script writes `tmp/rds.json` with the running endpoint. Three backends, picked in order:

1. **Real** — when `--real` is passed (or `MULE_DX_USE_REAL_RDS=1`). Defers to `start_real_rds.sh` which calls [go-runtime/start-rds.sh](file:///Users/tzeree/Salesforce/workspace/go-runtime/start-rds.sh). Brings up `rds` + `connector-service` via Docker Compose. Test-connection actually authenticates against real APIs (e.g. Twilio 401 on bogus creds). First-time bring-up is slow (~minutes for `go mod vendor` + `build-wasm-modules.sh` + image build).
2. **External** — when `MULE_DX_RDS_URL` is set and answers `/healthz`. Trust it, no spawn.
3. **Stub** (default) — spawns the local Node stub `helpers/rds_stub.mjs` on a free port. Wire-faithful but doesn't actually authenticate. Right for offline / Demo 2 walkthroughs.

After this step, `tmp/rds.json` carries `backend: "real" | "external" | "stub"`. Subsequent steps don't care which.

When running against real RDS, you can confirm which connectors are loaded:

```bash
bash scripts/list_rds_connectors.sh
```

The stub returns 404 here (handled with a clear note); only real RDS implements `/v1/connectors`.

## Step 3: Identify Systems and Trigger Hints

**[BLOCKER]** Do not prompt the user here. Produce prose only:

1. **Systems list** — exact connector names (e.g. `salesforce`, not "CRM"; we only have what's in the catalog so confirm against `references/go-connector-catalog.md`).
2. **Trigger hint** — verbatim phrase from the user ("every 60 seconds", "on incoming HTTP", "when a record is created"). Do not commit to a trigger choice; that's Step 6.

## Step 4: Pick connectors

For each system in the list:

```bash
bash scripts/search_connectors.sh <term>
```

Examine the ranked list. If exactly one row matches the user's intent, pick it:

```bash
bash scripts/pick_connector.sh <nick> <bundle-name>
```

If multiple rows could match (different vendor / different family), ask the user via `AskUserQuestion` — never guess. The cost of one prompt is one turn; the cost of a silent wrong pick is a full Phase 2 rewrite.

If `search_connectors.sh` exits non-zero, the connector isn't in the catalog. **Stop** and tell the user. Do not invent.

## Step 5: Describe each picked connector

```bash
bash scripts/describe_connector.sh <nick>
```

The stdout digest tells you:

- The DSL prefix and namespace.
- Operations + their required parameters.
- Sources (if any).
- Connection providers + their required fields.
- The config element name (e.g. `salesforce:sfdc-config`).

The full extension-model digest is cached at `tmp/connector-metadata/<nick>.json`. Read it with the `Read` tool when generating the flow XML at Step 9.

## Step 6: Trigger Selection

Decide the trigger using a short ladder:

1. **Connector source** — does any picked connector expose a `<source>` operation that matches the trigger hint? (Read the "sources:" line of each digest.) If yes, use it.
2. **Scheduler** — for "every N seconds/minutes" hints with no connector source.
3. **HTTP Listener** — for "on incoming HTTP" / "expose a webhook".
4. **Ask the user** — if none of the above clearly fits.

## Step 7: Connection Provider Selection

For each picked connector with `requiresConnection: true`, pick a provider from the digest's "connection providers:" list. Default to the first one with the simplest required-fields set unless the user specifies (e.g. "OAuth", "JWT"). Record the choice in the design-spec JSON you'll commit at Step 9.

## Step 8: Technical Design Summary + Approval Gate

Present prose summarizing:

- **Project name** (slug derived from the user's intent, e.g. `demo-sf-poller`).
- **User requirement** (one sentence).
- **Trigger** (kind + parameters).
- **Connectors picked** (each as `<bundle>` → `<prefix>:<config-element>`).
- **Connection providers** (one per connector, with required fields the user must fill in).
- **Project layout** that will be written: `.mule/project.json`, `project-manifest.json`, `mule-artifact.json`, stub `pom.xml`, `src/main/mule/<projectName>.xml`, `src/main/resources/config.yaml`. Connector descriptors are NOT copied into the project — they live in the warm cache at `~/AnypointCodeBuilder/.cache/go/<name>/`.

Then ask: **"Proceed to build?"** Wait for an explicit affirmative before Step 9.

---

# Phase 2: Build

## Step 9: Commit + Materialize

The agent assembles the design spec JSON, pipes it to `commit_design_spec.sh`, then calls `create_versionless_project.sh`, then writes the flow XML.

```bash
echo '<design-spec-json>' | bash scripts/commit_design_spec.sh
bash scripts/create_versionless_project.sh ~/Salesforce/projects/headless/<projectName>
```

The project directory must be a sibling of `tmp/` under `$WS_DIR` (default `~/Salesforce/projects/headless`). The agent passes the absolute path explicitly.

Design spec shape (passed on stdin to `commit_design_spec.sh`):

```json
{
  "projectName": "demo-sf-poller",
  "muleVersion": "4.11.0",
  "javaVersion": "17",
  "trigger": { "kind": "scheduler", "frequency": 60000, "timeUnit": "MILLISECONDS" },
  "connections": [
    { "nick": "salesforce", "configName": "Salesforce_Config", "providerName": "basic" }
  ]
}
```

After `create_versionless_project.sh` returns the project path, generate the flow XML with the `Write` tool against the cached connector digest.

**Read [`references/reference-flow-pattern.md`](references/reference-flow-pattern.md) before writing the XML.** It contains the canonical structure (modeled on `salesforce-accounts-to-twilio.xml`), a complete skeleton, and the failure modes to avoid.

**Start from a template** rather than from scratch. Pick the matching shape:
- [`references/flow-templates/scheduler.xml`](references/flow-templates/scheduler.xml) — "every N seconds" / polling
- [`references/flow-templates/http-listener.xml`](references/flow-templates/http-listener.xml) — incoming HTTP / webhooks
- [`references/flow-templates/connector-source.xml`](references/flow-templates/connector-source.xml) — when a connector exposes a source matching the trigger
- [`references/flow-templates/multi-connector-http.xml`](references/flow-templates/multi-connector-http.xml) — two connectors, HTTP-triggered (Salesforce → Twilio reference shape)

Substitute the `__TOKENS__` against the design spec + connector digests. Token guide lives in [`references/flow-templates/README.md`](references/flow-templates/README.md).

Quick checklist for the XML the agent writes:

- **Element names** come from the digest's `element=` field (sourced from `dsl.json`). Do not invent or guess — the Java connector and the Go bundle can use different element names for the same provider (e.g. `salesforce:basic-connection` vs `salesforce:basic`).
- **`xmlns` declarations**: always include `core` (default), `doc`, `ee`, `xsi`, plus `<prefix>` for each picked connector and `http` if HTTP listener is the trigger.
- **`xsi:schemaLocation`** has one space-separated `<namespace> <schemaLocation>` pair per declared `xmlns`. Pull `schemaLocation` from `tmp/connector-choices/<nick>.json`. Always include `core` and `ee/core` pairs.
- **`<configuration-properties file="config.yaml" />`** exactly once, child of `<mule>`.
- **One `<prefix>:<config-element>` per connector**, with the child `<prefix>:<provider-element>` carrying the required attributes as `${<connectorScope>.<provider>.<field>}` placeholders. The skill's `create_versionless_project.sh` writes `config.yaml` with matching keys.
- **`doc:name` and `doc:description`** on every meaningful element (configs, listeners, operations, transforms, error handlers) — these are how the canvas labels nodes.
- **`<error-handler>` at the end of each flow** with `<on-error-propagate type="ANY">`. Production flows handle errors; demo flows that skip this look broken in ACB.
- **DataWeave** belongs in `<ee:transform>` blocks with CDATA. Use `output application/json` for responses, `application/x-www-form-urlencoded` for form-posting connectors.
- **`target="<varName>"`** to capture an operation's output into a variable instead of overwriting `payload`.

## Step 9.5: Validate the flow XML

```bash
bash scripts/validate_generated_flow_xml.sh ~/Salesforce/projects/headless/<projectName>
```

Catches the failure modes the old `validate_before_build.sh` used to catch at `mvn package` time:

- `xmlns:foo="..."` declared without a matching `xsi:schemaLocation` pair
- `<foo:notARealElement>` not in any digest's known element set
- `<on-error-propagate type="FOO:NEVER_EXISTED">` — error type not in any connector's flat error list
- `config-ref="ghost"` with no top-level `name="ghost"` element
- `${dotted.key}` placeholder with no matching key in `config.yaml`

If validation fails, fix the XML and re-run before Step 10. The generator runs offline so this is the catch-net for typos and digest drift.

## Step 10: Render the flow (MCP tool — pending)

A dedicated MCP tool will render the canvas inline in Claude Desktop using the same renderer ACB ships, so the agent doesn't reimplement layout/iconography. Until that tool lands, Step 10 is a no-op — the agent surfaces the project path and tells the user to open it in ACB to see the canvas.

When the MCP tool ships, this step becomes a single tool call against the just-written `src/main/mule/<projectName>.xml`.

After Step 10:

```bash
bash scripts/stop_rds_stub.sh
rm -rf ~/Salesforce/projects/headless/tmp/
```

Tell the user: the project is at `~/Salesforce/projects/headless/<projectName>/`. They can open it in ACB to see the canvas. Test Connection on the connector config will hit the running RDS endpoint.

---

# Failure modes the skill exists to prevent

- **Reaching for anypoint-cli-v4.** This is the wrong skill if you're tempted. Switch to `build-mule-integration`.
- **Inventing a connector bundle.** Only bundles under `fixtures/go-connectors/` exist. If `search_connectors.sh` finds none, stop.
- **Inventing operation names or parameter names.** They live in the digest. If a parameter isn't in the digest, it's not a parameter of that operation.
- **Skipping the approval gate.** Step 8 is non-optional. Phase 2 can be irreversible (overwrites the project dir if it exists).
- **Pointing the skill at a real running ACB and expecting state sharing.** ACB spawns its own design-service instances; the skill's RDS stub is independent. If both want the same port, set `PORT=...` for the stub or `MULE_DX_RDS_URL=...` to share an external RDS.
