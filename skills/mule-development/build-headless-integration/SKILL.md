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
- The user names a connector that RDS doesn't have loaded yet — `bash "$SKILL/scripts/list_rds_connectors.sh"` shows the current catalog.

`$SKILL` here refers to the absolute path to the skill directory, recorded once at session start. The agent uses absolute invocations throughout — never `bash scripts/...` from a relative cwd.

If the right path is ambiguous, ask the user once with `AskUserQuestion`: "Headless / RDS path, or traditional Maven path?"

---

## Architecture (one paragraph)

RDS is the single source of truth. `GET /v1/connectors` lists what's available; `GET /v1/connectors/{name}/descriptor` returns the three artifacts (`extension-model.json`, `dsl.json`, `extension.xsd`) atomically. The skill writes them through to `$ACB_HOME/.cache/go/<name>/` (default `$HOME/AnypointCodeBuilder`) — the same warm cache the ACB plugin's `ManifestRdsExtensionModelSource` reads on project-open. The skill ships no local connector bundles; a one-time `bash "$SKILL/scripts/seed_cache.sh" --from-rds` populates the cache so subsequent picks succeed even when RDS goes down later. Test-connection goes through `POST /v1/test-connection`, the wire contract enforced by `HttpRemoteDesignServiceClient.java` in the ACB plugin. The project the skill produces matches the shape that the upgrade-to-versionless flow writes when migrating an existing Maven project: `project-manifest.json` (sibling of `pom.xml`, name-only connector list) plus a stub `pom.xml` so today's `WorkspaceManagerImpl` can still open the project.

---

## Prerequisites

```bash
node --version              # 18+
jq --version
curl --version
ls "$HOME/AnypointCodeBuilder"   # ACB install dir; override via ACB_HOME
```

Step 1 checks all of the above and writes `$WS_DIR/tmp/headless-env.json`. Stop if it exits non-zero.

---

## Workspace layout

All scripts share the same workspace root, controlled by the `WS_DIR` env var. **Default: `$HOME/Salesforce/projects/headless`** — set explicitly by the script defaults so the skill never scribbles wherever the agent's `$PWD` happens to point.

Layout under `WS_DIR`:

```
$WS_DIR/                                          # default: $HOME/Salesforce/projects/headless
├── tmp/                                          # scratch (Phase 1 state, RDS endpoint record)
│   ├── headless-env.json
│   ├── rds.json
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

$ACB_HOME/.cache/go/<name>/                       # warm cache (extension-model + dsl + xsd)
                                                  # default $ACB_HOME: $HOME/AnypointCodeBuilder
                                                  # populated by fetch_bundle.sh; read on project-open by
                                                  # ManifestRdsExtensionModelSource (no per-project bundles)
```

The split-file shape under `connector-metadata/` and `connector-errors/` mirrors what
the sibling `build-mule-integration` skill's `tmp/` produces — any tool that reads either skill's `tmp/` shape works against ours too.

Override per session if needed: `WS_DIR=/some/other/path bash "$SKILL/scripts/<name>.sh"`. All scripts honor it. `ACB_HOME` overrides the cache root (default `$HOME/AnypointCodeBuilder`).

The user opens `$WS_DIR/<projectName>/` in ACB after Step 7 — never `tmp/`. ACB then reads `project-manifest.json`, sees connector names, hits the warm `$ACB_HOME/.cache/go/<name>/` for descriptors, and the canvas renders.

---

## Bundled scripts

Invoke each script with the `Bash` tool. State persists under `$WS_DIR/tmp/` so later steps can read it mechanically.

| Script | Purpose | Output |
| --- | --- | --- |
| `scripts/validate_prerequisites.sh` | Step 1 — Node, jq, curl, ACB presence + auto-bring-up of RDS via `ensure_rds.sh`. Hard-fails if RDS isn't reachable and can't be started. | `tmp/headless-env.json` |
| `scripts/ensure_rds.sh` | Probe `MULE_DX_RDS_URL/healthz` (default `http://localhost:8090`). On miss, defers to `start_real_rds.sh`. Idempotent. | `tmp/rds.json` (`{url, managed, pid, backend: "real"}`) |
| `scripts/start_real_rds.sh [--rebuild\|down]` | Bring up the real RDS + ConnectivityService stack via `go-runtime/start-rds.sh`. Requires Docker + a `go-runtime` checkout (default `$HOME/Salesforce/workspace/go-runtime`; override via `GO_RUNTIME`). | `tmp/rds.json` (`backend: "real"`) |
| `scripts/list_rds_connectors.sh` | Probe `GET /v1/connectors` — list which connector binaries the running ConnectivityService has loaded, annotated with whether each is pickable (has a static `/descriptor` available). | stdout JSON |
| `scripts/search_connectors.sh <term>` | Optional helper — list connectors matching a term, sourced from RDS `GET /v1/connectors`. Format: `<name>\t<operations-count>` per line. Use for ad-hoc lookups; `phase1.sh` does not invoke this. | stdout |
| `scripts/pick_connector.sh <nick> <name>` | Called by `phase1.sh` (Step 2) — records the picked Go connector (resolves prefix, namespace, schemaLocation). Bundle resolution goes through `fetch_bundle.sh` (cache → RDS `/descriptor`). Callable standalone for re-picks. | `tmp/connector-choices/<nick>.json` |
| `scripts/fetch_bundle.sh <name>` | Resolve a connector bundle to a directory. Tries `$ACB_HOME/.cache/go/<name>/` (the same warm cache the ACB plugin reads on project-open), then `GET /v1/connectors/<name>/descriptor` (atomic 3-in-1 response) with write-through to the cache. Used by `pick_connector.sh`. | resolved bundle dir on stdout |
| `scripts/seed_cache.sh <name>... \| --from-rds` | One-shot pre-warm of `$ACB_HOME/.cache/go/<name>/` from RDS. Run once after a fresh checkout so subsequent picks succeed offline. | per-name status on stdout |
| `scripts/describe_connector.sh <nick>` | Called by `phase1.sh` (Step 2) — generates the rich digest + split per-shape files (flat reference, per-op metadata, per-config metadata, error whitelists). Stdout lists each operation/source/provider with its **DSL element name** (sourced from `dsl.json`) and required-param set. | `tmp/connector-metadata/<nick>-digest.json` (rich), `tmp/connector-metadata/<nick>.json` (flat reference), `tmp/connector-metadata/<nick>-<op>.json` (per-op), `tmp/connector-metadata/<nick>-config.json` (per-config), `tmp/connector-errors/<nick>.json` + `<nick>.<op>.json` |
| `scripts/phase1.sh <nick>:<connector> [...]` | **Step 2** — single-chip orchestrator that runs `validate_prerequisites` + `ensure_rds` + `pick_connector` + `describe_connector` for every connector pair, then prints a combined digest. Replaces 5+ separate bash chips. | per-script `tmp/` artifacts + combined stdout digest |
| `scripts/commit_design_spec.sh` | Step 6 — read agent-supplied design spec on stdin; merge picks into `tmp/design-spec.json` | `tmp/design-spec.json` |
| `scripts/create_versionless_project.sh <projectDir>` | Step 6 — write `.mule/project.json`, `project-manifest.json`, stub `pom.xml`, `mule-artifact.json`, dot-keyed `config.yaml`. No bundles inside the project — they live in the warm cache (`$ACB_HOME/.cache/go/<name>/`), pre-warmed during this step. | project on disk + cache pre-warmed |
| `scripts/validate_generated_flow_xml.sh <projectDir>` | Step 6.5 — validate the generated flow XML against the connector digests: schemaLocation pairs, known DSL element names, error types in `<on-error-propagate>`, `config-ref` resolution, `${...}` placeholders matching `config.yaml` keys. Cheap analogue of `validate_before_build.sh` from the build-mule-integration skill. | exit 0 on success; non-zero with stderr report on failure |
| `scripts/install_mcp_server.sh [--uninstall]` | One-time setup for Step 7 — venv + pip install + `claude_desktop_config.json` entry for the flow-canvas MCP server. Idempotent. | venv at `mcp/.venv/`, edited Claude Desktop config |

The agent generates the flow XML inline at Step 6 — bash does not call an LLM. The connector digest in `tmp/connector-metadata/<nick>.json` is the input.

**Always invoke scripts via absolute paths.** The skill is active under a fixed directory; record that path once at session start (e.g. `SKILL=$(pwd at activation)`) and use `"$SKILL/scripts/<name>.sh"` for every invocation. Never `bash scripts/...` from a relative-cwd assumption — the agent's `$PWD` may change between turns.

---

## Workflow shape (two phases)

This workflow has two phases separated by a hard user-approval gate.

- **Phase 1: Design (Steps 1–5).** Identify systems and trigger hint, run `phase1.sh` (one bash call that brings up RDS + picks + describes all connectors), pick a trigger and connection providers, present the Technical Design Summary, wait for approval. Phase 1 writes only to `tmp/`.
- **Phase 2: Build (Steps 6–7).** Materialize the project, generate the flow XML, validate, render the canvas. Phase 2 is the only phase that touches the user's project directory.

Phase 2 MUST NOT start until Step 5's approval gate passes explicitly.

## Workflow-wide discipline (read before Phase 1)

- **Always invoke scripts with absolute paths.** Record the skill directory once at session start, then call `"$SKILL/scripts/<name>.sh"`. The agent's working directory can change turn to turn; relative paths break unpredictably.
- **One bash invocation per response when it has side effects.** `ensure_rds.sh`, `commit_design_spec.sh`, and `create_versionless_project.sh` each run alone.
- **No stub fallback.** This skill targets the real RDS only. If `validate_prerequisites.sh` can't reach RDS (and `ensure_rds.sh` can't bring it up), STOP — surface the error and let the user fix the environment. Do not invent connector data or proceed without RDS.
- **Connector picks come from RDS only.** `search_connectors.sh` queries `GET /v1/connectors` for the live catalog. Never invent a name. If the search returns zero matches, tell the user that connector isn't loaded on RDS — do not silently fall back to a different connector or to HTTP.
- **The flow XML is the agent's responsibility.** Read the digest from `tmp/connector-metadata/<nick>.json`, then write `<projectDir>/src/main/mule/<projectName>.xml` directly with the `Write` tool. Use the prefix and namespace recorded in the digest. Do not invent operation names or required parameters — they're listed in the digest.
- **No anypoint-cli-v4 calls.** This skill never shells out to it. If you find yourself reaching for `anypoint-cli-v4 dx`, you're on the wrong skill — switch to `build-mule-integration`.

---

# Phase 1: Design

## Where to run this skill

**Run in the Claude Desktop chat tab (claude.ai web view).** That's the only surface that:
- Speaks the MCP UI extension (`io.modelcontextprotocol/ui`) needed to render the flow inline.
- Can iframe the canvas Step 7 produces.

The "code" tab (Claude Code CLI) and "workflow" tab (Cowork) cannot render the canvas. If a user asks for the skill from the code tab, the tool calls and bash chips work fine — but the final canvas at Step 7 will only show in the chat tab. Tell the user up front; don't surprise them at Step 7.

## Step 1: Identify Systems and Trigger Hints

**[BLOCKER]** Do not prompt the user here. Produce prose only:

1. **Systems list** — exact connector names (e.g. `salesforce`, not "CRM"). If unsure of the exact name, you can confirm against the live RDS catalog by running `bash "$SKILL/scripts/list_rds_connectors.sh"` (optional; Step 2 catches unknown connectors anyway).
2. **Trigger hint** — verbatim phrase from the user ("every 60 seconds", "on incoming HTTP", "when a record is created"). Do not commit to a trigger choice; that's Step 3. **Do not pre-announce a guess** ("most likely a Scheduler…") — that pre-commits the design before the user has a chance to react. If no hint was given, just say "no trigger hint given; will pick in Step 3".

## Step 2: Phase 1 — bring up RDS, pick + describe all connectors (one bash call)

```bash
bash "$SKILL/scripts/phase1.sh" <nick1>:<connector1> [<nick2>:<connector2> ...]
```

**Example:**
```bash
bash "$SKILL/scripts/phase1.sh" sfdc:salesforce twilio:twilio
```

Each pair binds a nickname (used as the local handle in the design spec + `config.yaml`) to a connector loaded on RDS.

What `phase1.sh` does in one go:

1. Validates prereqs (Node 18+, jq, curl, ACB install) and brings up the real Go RDS via `ensure_rds.sh` if not already running.
2. Picks each connector — fetches its descriptor (cache → RDS), records `tmp/connector-choices/<nick>.json` with prefix/namespace/schemaLocation.
3. Describes each connector — emits the rich digest to `tmp/connector-metadata/<nick>-digest.json` and the per-shape file family (flat reference, per-op, per-config, error whitelists).
4. Prints a combined digest to stdout: every operation, source, connection provider, and config element for every picked connector. The agent reads this single block to plan Steps 3–5.

**On failure:** the script aborts at the first failing step (set -e). Surface the stderr to the user. Common failure modes:
- Docker not running → RDS can't auto-bring-up. Tell the user to start Docker Desktop.
- `go-runtime` checkout missing → override with `GO_RUNTIME=/path/to/go-runtime` and rerun.
- Connector name not loaded on RDS → `phase1.sh` fails with `404 — connector '<name>' not loaded on RDS`. Run `list_rds_connectors.sh` to see what's available; pick a different connector or tell the user it's unavailable.
- Port 8090 occupied → override with `MULE_DX_RDS_URL=...` and rerun.

**Why this is one script, not five:** every separate bash invocation in the chat tab is a separate "Used Bash" chip + a fresh LLM round-trip. Phase 1 used to be 5+ chips for a 2-connector flow (validate, ensure_rds, pick × 2, describe × 2). Collapsing to one chip cuts ~30 seconds of perceived latency per session.

The individual scripts (`validate_prerequisites.sh`, `pick_connector.sh`, `describe_connector.sh`, etc.) still exist and are still callable on their own — `phase1.sh` is just a single-chip orchestrator. Use the individual scripts when:
- You're debugging one specific step (e.g., re-describe one connector after seeding a new descriptor).
- The user wants to add one more connector to an already-running design dialogue.

The full extension-model digest is cached at `tmp/connector-metadata/<nick>.json`. Read it with the `Read` tool when generating the flow XML at Step 6.

## Step 3: Trigger Selection

Decide the trigger using a short ladder. **Do not default to Scheduler** when the user gave no hint — Scheduler is the trigger that surprises users most (it implies background polling, which they didn't ask for). When in doubt, prefer HTTP Listener or ask.

1. **Connector source** — does any picked connector expose a `<source>` operation that matches the trigger hint? (Read the "sources:" line of each digest.) If yes, use it.
2. **Scheduler** — *only* when the user explicitly said "every N seconds/minutes", "poll", "on a schedule", "periodically", or similar timing language with no connector source available.
3. **HTTP Listener** — for "on incoming HTTP" / "expose a webhook" / "trigger on demand". This is also the default when no trigger hint was given and no connector source matches.
4. **Ask the user** — when an HTTP listener feels wrong for the integration's intent (e.g. the user described a long-running pipeline that doesn't naturally start from a request), use `AskUserQuestion` to choose between HTTP Listener and Scheduler before proceeding.

## Step 4: Connection Provider Selection

For each picked connector with `requiresConnection: true`, pick a provider from the digest's "connection providers:" list. Default to the first one with the simplest required-fields set unless the user specifies (e.g. "OAuth", "JWT"). Record the choice in the design-spec JSON you'll commit at Step 6.

## Step 5: Technical Design Summary + Approval Gate

Present prose summarizing:

- **Project name** (slug derived from the user's intent, e.g. `demo-sf-poller`).
- **User requirement** (one sentence).
- **Trigger** (kind + parameters).
- **Connectors picked** (each as `<bundle>` → `<prefix>:<config-element>`).
- **Connection providers** (one per connector, with required fields the user must fill in).
- **Project layout** that will be written: `.mule/project.json`, `project-manifest.json`, `mule-artifact.json`, stub `pom.xml`, `src/main/mule/<projectName>.xml`, `src/main/resources/config.yaml`. Connector descriptors are NOT copied into the project — they live in the warm cache at `$ACB_HOME/.cache/go/<name>/`.

Then ask: **"Proceed to build?"** Wait for an explicit affirmative before Step 6.

---

# Phase 2: Build

## Step 6: Commit + Materialize

The agent assembles the design spec JSON, pipes it to `commit_design_spec.sh`, then calls `create_versionless_project.sh`, then writes the flow XML.

```bash
echo '<design-spec-json>' | bash "$SKILL/scripts/commit_design_spec.sh"
bash "$SKILL/scripts/create_versionless_project.sh" "$WS_DIR/<projectName>"
```

The project directory must be a sibling of `tmp/` under `$WS_DIR` (default `$HOME/Salesforce/projects/headless`). The agent passes the absolute path explicitly.

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

**Read [`references/reference-flow-pattern.md`](references/reference-flow-pattern.md) before writing the XML.** It contains the canonical skeleton, the trigger-block variants (HTTP listener, scheduler, connector source), the Java-vs-Go connector form table, and the failure-mode rules. Generate the XML directly from the digest using that doc — there are no separate template files to fill in.

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

## Step 6.5: Validate the flow XML

```bash
bash "$SKILL/scripts/validate_generated_flow_xml.sh" "$WS_DIR/<projectName>"
```

Catches the failure modes the old `validate_before_build.sh` used to catch at `mvn package` time:

- `xmlns:foo="..."` declared without a matching `xsi:schemaLocation` pair
- `<foo:notARealElement>` not in any digest's known element set
- `<on-error-propagate type="FOO:NEVER_EXISTED">` — error type not in any connector's flat error list
- `config-ref="ghost"` with no top-level `name="ghost"` element
- `${dotted.key}` placeholder with no matching key in `config.yaml`

If validation fails, fix the XML and re-run before Step 7. The generator runs offline so this is the catch-net for typos and digest drift.

## Step 7: Render the flow inline

The skill ships a companion MCP server at [`mcp/`](mcp/README.md) that renders the generated flow as an interactive React Flow canvas in the Claude Desktop chat. After the project exists on disk and validation passes, call:

```
render_mule_flow(project_dir="$WS_DIR/<projectName>")
```

The tool reads `<project_dir>/src/main/mule/<name>.xml`, parses it into a `{nodes, edges}` graph (one node per top-level processor; containers like `<choice>`/`<try>` collapse to one summary node), and returns a UI resource Claude Desktop iframes inline. Click any node in the canvas to see its XML attributes in a side panel. The canvas is read-only — flow edits go through the chat (the agent regenerates the project).

**The renderer has no RDS dependency.** It reads only the project's flow XML and bundled connector icons; once the project is on disk, the canvas works whether RDS is up or down.

### When `render_mule_flow` is NOT available as an MCP tool

This means Claude Desktop hasn't been told about the server yet (the skill folder by itself doesn't auto-register the MCP server with Claude Desktop). Run the bundled installer once:

```bash
bash "$SKILL/scripts/install_mcp_server.sh"
```

The installer (idempotent, safe to re-run):
1. Creates a Python venv at `mcp/.venv/` using a 3.11+ interpreter.
2. Runs `pip install -e mcp/` so the `build-headless-integration-mcp` console script lands on the venv's PATH.
3. Adds an `mcpServers.mule-flow-canvas` entry to `~/Library/Application Support/Claude/claude_desktop_config.json` (existing entries preserved; existing config backed up to `claude_desktop_config.json.bak.<timestamp>`).

After the installer prints "Installed", **the user must quit and relaunch Claude Desktop** (⌘Q → reopen). MCP servers spawn at app start; a hot config reload registers the server but the iframe pipeline only initialises once per app lifetime.

To uninstall: `bash "$SKILL/scripts/install_mcp_server.sh" --uninstall`.

### Fallback when the MCP server cannot be installed

If the user can't install the server (no Python 3.11+, no Claude Desktop, etc.), tell them they can open the project in ACB to see the same canvas — different surface, same data. Do not silently skip Step 7. Either render, surface the install path, or surface the ACB fallback.

After Step 7:

```bash
rm -rf "$WS_DIR/tmp/"   # optional — keep tmp/ if you'll re-run the skill
```

Leave RDS running for ACB. Tell the user: the project is at `$WS_DIR/<projectName>/` (default `$HOME/Salesforce/projects/headless/<projectName>/`). They can open it in ACB to see the canvas. Test Connection on the connector config will hit the running RDS endpoint at `MULE_DX_RDS_URL` (default `http://localhost:8090`).

To stop RDS later:

```bash
bash "$SKILL/scripts/start_real_rds.sh" down
```

---

# Failure modes the skill exists to prevent

- **Reaching for anypoint-cli-v4.** This is the wrong skill if you're tempted. Switch to `build-mule-integration`.
- **Inventing a connector name.** Only connectors RDS has loaded exist. `bash "$SKILL/scripts/list_rds_connectors.sh"` prints the live catalog. If `search_connectors.sh` finds none, stop.
- **Inventing operation names or parameter names.** They live in the digest. If a parameter isn't in the digest, it's not a parameter of that operation.
- **Skipping the approval gate.** Step 5 is non-optional. Phase 2 can be irreversible (overwrites the project dir if it exists).
- **Proceeding without RDS.** Step 1 hard-fails if RDS isn't reachable. There is no stub fallback. If `validate_prerequisites.sh` exits non-zero, surface the error to the user and stop — do not invent connector data or skip ahead.
