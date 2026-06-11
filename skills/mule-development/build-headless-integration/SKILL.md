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

### Project-file invariants

These are not stylistic conventions — they're load-bearing for the platform's `WorkspaceManagerImpl` to open the project at all. `create_versionless_project.sh` writes them in the right shape; **never modify the script to omit one of these fields without confirming the platform supports it**:

- **`.mule/project.json` MUST carry a `source` field** pointing at the stub `pom.xml` as a `file://` URI. `WorkspaceManagerImpl.initializeProjectFromExistingDescriptor` calls `Path.of(descriptor.getSource())` on its first line; a null `source` throws NPE, the workspace fails to initialize, and the canvas hangs at `MuleClient registration timed out after 60000ms`. This is the gating field — drop it and ACB silently dies on project-open.
- **`pom.xml` MUST exist next to `.mule/`**, even though Go connectors aren't Maven artifacts. The same `WorkspaceManagerImpl` calls `Files.exists(root.resolve(POM_FILE))` and bails when it's missing. The stub the script emits has no connector dependencies; it's there to satisfy the file-existence check.
- **`project-manifest.json` carries the connector list, name-only.** The plugin's `ManifestRdsExtensionModelSource.loadAll` reads this — not `.mule/project.json`. Don't try to put connectors in both files; the platform reads them from the manifest and the workspace descriptor must stay slim.
- **`MULE_DX_RDS_MODE=dev` and `MULE_DX_RDS_URL=...` must be visible to ACB's process.** macOS GUI apps don't read `~/.zshrc`; the user must set them via `launchctl setenv` (or a `~/Library/LaunchAgents/*.plist` with `RunAtLoad=true`) for installed-mode ACB to inherit them. Without these, `RemoteDesignServiceClientFactory.create()` returns the prod stub and Go-connector test-connection silently returns "not available". The dev-mode VS Code window inherits `.zshrc`-set vars; installed-mode doesn't.

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
| `scripts/build_mcpb.sh` | Step 7 (recommended install path) — package `mcp/` into a single-click `.mcpb` bundle the user installs by double-clicking it in Claude Desktop. Wraps `mcpb pack`; requires `npm i -g @anthropic-ai/mcpb` once on the build host. | `mcp/build/mule-flow-canvas-<version>.mcpb` |
| `scripts/install_mcp_server.sh [--uninstall]` | Step 7 (dev-loop fallback) — venv + `pip install -e` + `claude_desktop_config.json` entry for the flow-canvas MCP server. Use when `.mcpb` isn't available or you want a live-edit dev install. Idempotent. | venv at `mcp/.venv/`, edited Claude Desktop config |

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
- **Trust phase1.sh's stdout — do not re-Read `tmp/connector-metadata/*.json` files.** `phase1.sh` prints a complete combined digest in one block: every operation, source, connection provider, error type, and required-param set for every picked connector. After phase1.sh completes, the next move is Step 3 (trigger ladder), NOT a series of `Read tmp/connector-metadata/twilio-sendMessage.json` chips. Re-reading per-op files individually is the chip-count smell that bloats Phase 1 from ~1 chip to 10+. Use `jq` against an on-disk file ONLY when you need a specific field that the printed digest didn't include (rare — usually `parameterModels` for an obscure config).
- **Project files come from `create_versionless_project.sh` — never inline-emit them yourself.** Phase 2 has exactly one writer for `.mule/project.json`, `project-manifest.json`, `pom.xml`, `mule-artifact.json`, and `src/main/resources/config.yaml`: the script. Do NOT `Write` or `cat <<EOF >config.yaml` from a Bash chip — even when you know the exact contents the script would emit. Bare-name writes from a cwd of `$WS_DIR` land at `$WS_DIR/config.yaml` instead of `$WS_DIR/<projectName>/src/main/resources/config.yaml`, polluting the workspace root with orphan files. The agent's only direct write in Phase 2 is the flow XML at `$WS_DIR/<projectName>/src/main/mule/<projectName>.xml`. Everything else is the script's job.
- **Never `mkdir` paths under `$WS_DIR` directly.** `create_versionless_project.sh` creates the full directory tree the project needs (`.mule/`, `src/main/mule/`, `src/main/resources/`, `src/test/mule/`). If you find yourself running `mkdir services/` or any other bare-name directory, you're working around the script — stop and call the script with the right `<projectDir>` instead.
- **Java connector forms ≠ Go connector forms — read the digest, not training-time intuition.** The Mule 4 Java connectors (what `build-mule-integration` produces) and the Go bundles loaded on RDS often model the same operation with different XML shapes. Concrete examples: the Java `salesforce:query` carries SOQL as a child element `<salesforce:salesforce-query>...</salesforce:salesforce-query>`; the Go connector carries it as the attribute `soql="..."`. The Java HTTP connector nests `<http:listener-connection>` inside `<http:listener-config>`; the Go HTTP connector uses `<http:listener>` directly under `<http:listener-config>` (and ALSO has a `<http:listener>` source on the flow — same element name, different role, both legitimate). The digest's `dslElementNames`, `parameterGroups[].parameters[].name`, and per-parameter `required` flag are the only authoritative source. If you find yourself reaching for the build-mule-integration reference XML or the salesforce-accounts-to-twilio testdata to "look up the right shape", stop — those are Java forms and won't match the Go descriptor. Validator Check 6 catches this drift at Step 6.5; respect it.

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
# → also picks + describes http (defensive auto-add — see below)
```

Each pair binds a nickname (used as the local handle in the design spec + `config.yaml`) to a connector loaded on RDS.

**Defensive `http` auto-add.** `phase1.sh` always picks + describes the `http` connector unless you pass `--no-http`. Most realistic headless integrations need it: HTTP listener triggers, outbound REST calls, and OAuth callback paths all require the `http` connector's `<http:listener-config>` / `<http:listener>` / `<http:request>` elements. Including it in Phase 1 means Step 3's `sources[]` view already lists `http:listener` as an option without a separate "now also pick http" round-trip. Pass `--no-http` only when you're sure the integration touches no HTTP at all (rare).

What `phase1.sh` does in one go:

1. Validates prereqs (Node 18+, jq, curl, ACB install) and brings up the real Go RDS via `ensure_rds.sh` if not already running.
2. Picks each connector (including `http` unless `--no-http`) — fetches its descriptor (cache → RDS), records `tmp/connector-choices/<nick>.json` with prefix/namespace/schemaLocation.
3. Describes each connector — emits the rich digest to `tmp/connector-metadata/<nick>-digest.json` and the per-shape file family (flat reference, per-op, per-config, error whitelists).
4. Prints a combined digest to stdout: every operation, source, connection provider, and config element for every picked connector. The agent reads this single block to plan Steps 3–5. **This stdout block is the only digest the agent should be reading** — see "Trust phase1.sh's stdout" in the workflow-wide discipline.

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

**[BLOCKER] Read every connector's `sources:` line before deciding.** Step 2's `phase1.sh` printed the combined digest for every picked connector; the `sources:` line is the authoritative list of native triggers each one supports. Scrolling past it and committing to Scheduler / HTTP Listener is the single highest-impact failure mode of this step — a connector source matched to user intent is always a better trigger than a generic poller or webhook.

If the digest's `sources:` arrays are not visible in the current tool output (e.g. they scrolled away), re-print them before deciding:

```bash
for f in "$WS_DIR"/tmp/connector-metadata/*-digest.json; do
  echo "--- $(basename "$f") ---"
  jq '{prefix, sources: [.configurations[].sources[]? | {name, element}]}' "$f"
done
```

### Decision ladder (evaluate in order)

Each rung is one of the possible paths — there is no "fallback". The first rung whose preconditions all match is the one you take.

#### Rung 1 — Connector source path

Take this path when **any** picked connector exposes a source whose name plausibly matches the user's trigger hint. Match heuristic: noun overlap (`product`, `order`, `charge`, `record`, `topic`) AND verb-prefix consistency (`on-new-*`, `on-modified-*`, `on-*-arrived`, `*-listener`, `*-trigger`, `replay-*`).

Read the digest's per-source shape (the `parameterGroups` block in the source's entry under `configurations[].sources[]`). Two sub-cases:

- **Polling source** — the source's parameters include scheduling fields (e.g. `frequency`, `startDelay`, `timeUnit`). The connector handles cadence natively. When the user named a cadence, the cadence goes into the source's parameters. **Do NOT add a separate top-level `<scheduler>`** — that double-clocks the flow.
- **Event source** — no scheduling fields; fires on a real upstream event. Use directly.

Commit inline when exactly one source's shape fits. Use `AskUserQuestion` when two or more sources both pass the shape check (the agent picking blindly between them is the wrong move).

#### Rung 2 — Scheduler path

Take this path when:

- Rung 1 examined every `sources:` array and none matched the user's intent, AND
- The user's prompt explicitly named a cadence ("every N seconds/minutes", "poll", "on a schedule", "periodically", "hourly", "daily"), AND
- The flow body will call connector operations (not event-driven).

Use `<scheduler>` with `<scheduling-strategy><fixed-frequency .../></scheduling-strategy>` (or `<cron .../>` for time-of-day cadences). **Record one-line reasons each connector source was rejected** in the Step 5 TDD — Phase 2 cannot start without that list when a Rung-1 source existed.

#### Rung 3 — HTTP Listener path

Take this path when:

- The prompt explicitly says "expose endpoint", "receive HTTP", "webhook at /path", "REST API", "trigger on demand", AND
- No connector source in scope is a webhook-style receiver.

Use `<http:listener>` with the `http` connector — already loaded by `phase1.sh`'s defensive auto-add. **Default to this rung over Scheduler** when the prompt has no trigger hint and no connector source matched — Scheduler implies background polling the user didn't ask for, while HTTP Listener is inert until invoked.

**Element-name reuse — read carefully.** The Go `http` connector's digest shows the name `listener` in two distinct places, and they are NOT in conflict:

1. Under `configurations[].connectionProviders[]` — the **connection element** that goes inside `<http:listener-config>` and carries `host` + `port`. Element name: `listener`. This means the XML reads `<http:listener-config><http:listener host="0.0.0.0" port="8081"/></http:listener-config>` — the connection element is literally `<http:listener>`. (If you've worked with the Java connector, the equivalent there is `<http:listener-connection>`. The Go bundle doesn't have that — `<http:listener>` is the connection element directly.)
2. Under `configurations[].sources[]` — the **flow source** with required `path` + optional `allowedMethods` + a `config-ref` pointing at the listener-config. Element name: `listener`. This means the XML reads `<http:listener config-ref="HTTP_Listener_Config" path="/foo">...</http:listener>` — same element name, different context (top-level inside a `<flow>`, not inside a `<listener-config>`).

This is **not** "schema-ambiguous" or a descriptor bug. XML disambiguates the two by parent context: a `<listener>` inside `<listener-config>` is the connection element; a `<listener>` inside `<flow>` is the source. Both are valid and must be present for an HTTP-triggered flow. If you find yourself questioning the source's existence because `dslElementNames` lists `listener` only once — stop and re-read `configurations[].sources[]` directly; the source IS there.

#### Rung 4 — Ask the user

Take this path when none of Rungs 1–3 clearly apply — e.g. the prompt is outbound-only ("makes a request", "fetches", "retrieves") with no cadence, no endpoint language, and no source matched. Use `AskUserQuestion` with options derived from the actual `sources:` arrays of connectors in scope, plus Scheduler and HTTP Listener as fallbacks.

### After the decision

Record the selected trigger and — if the path is Rung 2 or Rung 3 and any in-scope connector has a `sources:` entry — the list of sources considered with one-line rejection reasons. Step 5's TDD surfaces this list; if it's missing, the TDD is incomplete and Phase 2 cannot start.

## Step 4: Connection Provider Selection

For each picked connector whose digest shows `requiresConnection: true`, pick a provider from the digest's `connectionProviders` list under `configurations[]`.

- **Exactly one provider** → state the choice inline ("Using `salesforce:basic` — only provider exposed by the connector"). Don't prompt.
- **Multiple providers with materially different credentials** (e.g. `basic` vs `jwt` vs `saml`) → use `AskUserQuestion`. Show each provider's required fields so the user can pick by what they have credentials for, not by name.

Record the choice as `(configName, providerName)` per connector. Step 5 surfaces it in the TDD; Step 6's `commit_design_spec.sh` reads it.

## Step 5: Technical Design Summary + Approval Gate

**[BLOCKER] Present ONLY after Steps 1–4 are complete.** Every connector must have a digest under `tmp/connector-metadata/<nick>-digest.json`, every provider must be selected, and — when Step 3's rung was 2 or 3 — every Rung-1 source dismissal must be recorded. If any of those is missing, go back to the relevant step. Do not paper over with "TBD".

Present prose summarizing:

- **Project name** (slug derived from the user's intent, e.g. `demo-sf-poller`).
- **User requirement** (the user's prompt, verbatim or near-verbatim).
- **Trigger** — kind + parameters. If the path was Rung 2 or Rung 3, also list every `sources:` entry that was considered with one-line dismissal reasons.
- **Connectors picked** — each as `<bundle>` → `<prefix>:<config-element>` with the connector's namespace + schemaLocation from `tmp/connector-choices/<nick>.json`.
- **Connection providers** — one per connector, with the required fields the user must fill into `config.yaml` after Phase 2.
- **Project layout** — `.mule/project.json`, `project-manifest.json`, `mule-artifact.json`, stub `pom.xml`, `src/main/mule/<projectName>.xml`, `src/main/resources/config.yaml`. Connector descriptors are NOT copied into the project; they live in `$ACB_HOME/.cache/go/<name>/` (pre-warmed by `create_versionless_project.sh`).

Then ask via `AskUserQuestion`:

```
"Please review the technical design above. Proceed to build?"
  - "Yes, proceed to build."
  - "No, I want to change the plan."
  - "No, cancel generation."
```

**[BLOCKER] WAIT for explicit "Yes, proceed to build." before Step 6.** On "No, I want to change the plan.", ask which part (trigger, connectors, providers) and loop back to the relevant step. On "No, cancel generation.", stop the workflow politely.

Why this gate matters: Phase 1 is the last chance to catch a wrong trigger, a wrong connector, or a missing clarifying question. Once Phase 2 begins the project skeleton is on disk and rewinding it costs everyone time. Treat "No, I want to change the plan." as a first-class outcome, not an exception.

---

# Phase 2: Build

## Step 6: Commit + Materialize

**[BLOCKER] Step 5's "Yes, proceed to build." must have been received before this step runs.** Phase 2 writes to disk and pre-warms `$ACB_HOME/.cache/go/<name>/`; rewinding either is more expensive than completing Phase 1 properly.

The agent assembles the design spec JSON, pipes it to `commit_design_spec.sh`, then calls `create_versionless_project.sh`, then writes the flow XML.

```bash
echo '<design-spec-json>' | bash "$SKILL/scripts/commit_design_spec.sh"
bash "$SKILL/scripts/create_versionless_project.sh" "$WS_DIR/<projectName>"
```

The project directory must be a sibling of `tmp/` under `$WS_DIR` (default `$HOME/Salesforce/projects/headless`). The agent passes the absolute path explicitly.

**Existing-project guard.** `create_versionless_project.sh` refuses to run when `<projectDir>/.mule/project.json` already exists — re-running on a project the user has hand-edited would silently overwrite their changes. Two ways to proceed:

- The user wants a fresh emit and is OK losing their hand-edits → re-run with `--force`:
  ```bash
  bash "$SKILL/scripts/create_versionless_project.sh" --force "$WS_DIR/<projectName>"
  ```
- The user is iterating on the design and wants both versions on disk → emit to a new directory (different `<projectName>`).

Don't pass `--force` silently. If the user didn't ask for it, surface the conflict and ask via `AskUserQuestion`.

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

**[BLOCKER] Run the validator before Step 7.** The validator runs offline against the digest cache; running it costs nothing and catches typos that ACB would only surface at canvas-render time. Treat a non-zero exit as "fix the XML, re-run", not "good enough".

```bash
bash "$SKILL/scripts/validate_generated_flow_xml.sh" "$WS_DIR/<projectName>"
```

Six checks, in order:

1. `xmlns:foo="..."` declared without a matching `xsi:schemaLocation` pair.
2. `<foo:notARealElement>` not in any digest's `dslElementNames` set.
3. `<on-error-propagate type="FOO:NEVER_EXISTED">` — error type not in any connector's flat error list.
4. `config-ref="ghost"` with no top-level `name="ghost"` element.
5. `${dotted.key}` placeholder with no matching key in `config.yaml`.
6. **Per-element attribute coverage.** Every attribute on `<prefix:elementName>` must appear in that element's `parameterGroups[].parameters[].name` set in the digest. Catches Java-vs-Go connector attribute drift, e.g. writing `<salesforce:query salesforceQuery="...">` when the Go descriptor declared `soql`. Universal attrs (`name`, `config-ref`, `target`, `targetValue`, `doc:*`, `xmlns:*`, `xsi:*`) are exempt.

Check 6 defers when the digest declared zero parameters for an element (some configurations have `parameterModels: null`); a cleaner false-negative is preferred to a flaky false-positive there.

## Step 7: Render the flow inline

The skill ships a companion MCP server at [`mcp/`](mcp/README.md) that renders the generated flow as an interactive React Flow canvas in the Claude Desktop chat. After the project exists on disk and validation passes, call:

```
render_mule_flow(project_dir="$WS_DIR/<projectName>")
```

The tool reads `<project_dir>/src/main/mule/<name>.xml`, parses it into a `{nodes, edges}` graph, and returns a UI resource Claude Desktop iframes inline. Click any node in the canvas to see its XML attributes in a side panel. The canvas is read-only — flow edits go through the chat (the agent regenerates the project).

**v1 limitations — call these out to the user up front so the canvas doesn't surprise them.** The MCP renderer is a flat-tree visualiser; nested control-flow structure is collapsed:

- **Containers (`<choice>`, `<try>`, `<scatter-gather>`, `<foreach>`, `<until-successful>`, `<parallel-foreach>`)** render as a single summary node — the children inside them are NOT shown as separate nodes in the canvas. The `<error-handler>` block at the end of a flow is similarly collapsed.
- **Per-connector icons** are not rendered; nodes show generic kind badges instead.
- **Edit-from-canvas** is not supported. Any flow change goes through the chat — the agent edits the XML and the next `render_mule_flow` call picks up the change.

If the user needs to see the full nested structure (the children inside `<choice>`'s `<when>` / `<otherwise>`, or the `<try>`'s body separated from its `<error-handler>`), tell them to open the project in ACB. Same XML, same connector icons, full nested layout — the canvas there is the authoritative one. The MCP renderer is the inline-in-chat fallback, not a replacement for ACB.

**The renderer has no RDS dependency.** It reads only the project's flow XML and bundled connector icons; once the project is on disk, the canvas works whether RDS is up or down.

### When `render_mule_flow` is NOT available as an MCP tool

Claude Desktop hasn't been told about the server yet — the skill folder by itself doesn't auto-register the MCP server. Two install paths, in preference order:

#### Option 1 — Install the `.mcpb` bundle (recommended)

The skill ships an Anthropic-standard MCP Bundle (`.mcpb`) the user installs by double-clicking. It registers the server in Claude Desktop's UI with a proper Settings → Extensions entry — and `uv` (bundled with Claude Desktop on macOS / Windows) resolves the Python deps on first launch, no host-side Python or pip required.

Build the bundle once from a checkout (one-time prereq: `npm i -g @anthropic-ai/mcpb`):

```bash
bash "$SKILL/scripts/build_mcpb.sh"
# → writes <skill>/mcp/build/mule-flow-canvas-<version>.mcpb
```

Then install it:

```bash
open "<skill>/mcp/build/mule-flow-canvas-<version>.mcpb"
```

Claude Desktop opens an install dialog. Approve, **quit + relaunch Claude Desktop** (⌘Q → reopen — MCP servers spawn at app start), and `render_mule_flow` becomes available.

To uninstall: Claude Desktop → Settings → Extensions → "Mule Flow Canvas" → Uninstall.

#### Option 2 — `claude_desktop_config.json` install (dev-loop fallback)

Use this when the user can't install the `.mcpb` (no `mcpb` CLI on the build host, no `uv` available, or they want a live-edit dev-mode install via `pip install -e`):

```bash
bash "$SKILL/scripts/install_mcp_server.sh"
```

The installer (idempotent, safe to re-run):
1. Creates a Python venv at `mcp/.venv/` using a 3.11+ interpreter.
2. Runs `pip install -e mcp/` so the `build-headless-integration-mcp` console script lands on the venv's PATH.
3. Adds an `mcpServers.mule-flow-canvas` entry to `~/Library/Application Support/Claude/claude_desktop_config.json` (existing entries preserved; existing config backed up to `claude_desktop_config.json.bak.<timestamp>`).

After the installer prints "Installed", quit + relaunch Claude Desktop.

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

## Best Practices

**1. RDS is the only source of connector truth.** No stub fallback. No invention.

- ✅ `tmp/connector-metadata/<nick>.json` exists on disk → that nick is real.
- ✅ The digest's `dslElementNames`, `parameterGroups[].parameters[].name`, and `errorTypes` are the only attribute / element / error-type identifiers allowed in the flow XML.
- ❌ Pasting an attribute name from `build-mule-integration` patterns (Java connector) into a Go-connector flow. They differ — the Go `salesforce` connector declares `soql`; the Java connector's `salesforce-query` child element lives there. Check 6 of `validate_generated_flow_xml.sh` catches this mechanically; respect it.
- ❌ Inventing a connector name when `list_rds_connectors.sh` doesn't list it. The Go connector module isn't loaded — STOP, don't fall back to HTTP, don't pick a different connector. Tell the user.

**2. The agent writes the flow XML directly.** No bash call to an LLM. Read the digest, write the file.

- The digest has element names, attribute names, required-flags, and error types. That's the authoritative spec.
- Use the prefix and namespace recorded in `tmp/connector-choices/<nick>.json` — same pair the canvas will use to look up the descriptor.
- Validate before declaring done. `validate_generated_flow_xml.sh` runs offline; running it costs nothing and catches typos that ACB would only surface on render.

**3. Reaching for anypoint-cli-v4 means you're on the wrong skill.** Switch to `build-mule-integration`. This skill produces no `pom.xml` dependencies, no Maven build, no MTF — the stub `pom.xml` exists only because today's `WorkspaceManagerImpl` requires the file to exist.

**4. Phase 2 is destructive — never silently re-run it on an existing project.** `create_versionless_project.sh` refuses to overwrite an existing `.mule/project.json`. If the user wants a clean re-emit, pass `--force` explicitly; otherwise pick a new project directory or surface the conflict to the user.

**5. Don't trust the dev-mode env to match installed-mode env.** When the user reports the canvas works in dev mode but not in installed-mode ACB, the most common cause is that `MULE_DX_RDS_MODE` and `MULE_DX_RDS_URL` are exported in `.zshrc` (which dev-mode VS Code inherits) but not in the launchd `gui/<uid>` domain (which dock-launched ACB inherits). See "Project-file invariants" in the Architecture section.

---

## Common Headless Integration Patterns

**#1 HTTP listener → Go-connector operation → response.** `<http:listener>` → `<salesforce:query>` → `<ee:transform>` → response. Use when the user wants a webhook-driven sync. HTTP listener is the right default when the prompt has no cadence and no native source matches.

**#2 Scheduler → Go-connector query → transform → downstream.** `<scheduler>` with `<fixed-frequency>` → `<salesforce:query>` → `<ee:transform>` → `<twilio:send-sms>`. Use only when the user explicitly named a cadence ("every N seconds", "poll", "on a schedule"). Don't default to Scheduler — it implies background polling the user didn't ask for.

**#3 Native event source → transform → downstream.** `<salesforce:replay-topic-listener>` → `<ee:transform>` → target operation. Use when the picked connector exposes a `source` (visible as a `sources:` line in the digest) that matches the trigger hint. Always preferred over Scheduler when a real event source exists.

**#4 Multi-target fan-out via `<flow-ref>`.** Trigger → `<flow-ref name="enrich"/>` → `<scatter-gather>` → multiple connectors. Use when the user says "send to X and Y" — separate top-level flows let each leg fail independently.

For all four patterns, the canvas labels rendered in ACB and in the MCP renderer (Step 7) come from `doc:name` and `doc:description` attributes — every meaningful element gets both.

---

## Troubleshooting

**`MuleClient registration timed out after 60000ms` on project open.** Almost always a `.mule/project.json` defect. Check that `source` is populated (`file:///.../pom.xml`); that file is the gating field for `WorkspaceManagerImpl.initializeProjectFromExistingDescriptor`. See "Project-file invariants" above.

**`spawn ENOENT` for the bundled JDK in ACB logs.** Usually a symptom, not a cause. Look at `~/AnypointCodeBuilder/logs/ACBLog-YYYY-MM-DD.log` for the real exception — the JDK error is the auto-restart racing against shutdown.

**Test Connection returns "not available" / empty.** Either RDS isn't running (run `bash "$SKILL/scripts/ensure_rds.sh"` to bring it up) or `MULE_DX_RDS_MODE` / `MULE_DX_RDS_URL` aren't visible to ACB (`launchctl getenv MULE_DX_RDS_MODE` should print `dev`). If installed-mode ACB still doesn't see them, the launchd plist needs to be reloaded: `launchctl bootout gui/$(id -u)/<plist-id>; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>`.

**Docker not running → RDS can't auto-bring-up.** Tell the user to start Docker Desktop. `start_real_rds.sh` preflights this and reports clearly.

**`go-runtime` checkout missing.** Override with `GO_RUNTIME=/path/to/go-runtime` in the environment and rerun the failing script. Default location is `$HOME/Salesforce/workspace/go-runtime`.

**Connector name not loaded on RDS.** `phase1.sh` fails with `404 — connector '<name>' not loaded on RDS`. Run `list_rds_connectors.sh` to see what's available. If the connector the user wants isn't there, tell them — don't silently switch to a different one.

**Port 8090 occupied.** Override with `MULE_DX_RDS_URL=http://localhost:<other>:` and rerun.

**MCP `render_mule_flow` tool not available.** Claude Desktop hasn't been told about the server yet. Two install paths — the `.mcpb` bundle (recommended; `bash "$SKILL/scripts/build_mcpb.sh"` then `open` the artifact) or the dev-loop installer (`bash "$SKILL/scripts/install_mcp_server.sh"`). Either way, quit + relaunch Claude Desktop after install.

**Validator Check 6 false-positive.** If the validator reports an attribute isn't in the digest but the digest is current, it's likely a digest-shape bug. Re-run `phase1.sh` to refresh `tmp/connector-metadata/<nick>-digest.json`. The check defers (passes) when the digest declared zero attributes for an element, so config-level elements with `parameterModels: null` don't false-flag.

---

## Quick Reference

`$SKILL` is the absolute path to this skill's directory. Record it once at session start and use it consistently — never `bash scripts/...` from a relative cwd.

```bash
# Phase 1 — single-chip orchestrator (validate + ensure RDS + pick + describe per nick)
bash "$SKILL/scripts/phase1.sh" <nick1>:<connector1> [<nick2>:<connector2> ...]

# Optional helpers (ad-hoc; not invoked by phase1.sh)
bash "$SKILL/scripts/list_rds_connectors.sh"               # what's loaded on RDS right now
bash "$SKILL/scripts/search_connectors.sh" <term>          # filter the live catalog
bash "$SKILL/scripts/seed_cache.sh" --from-rds             # one-time pre-warm $ACB_HOME/.cache/go/

# Phase 2 — commit, materialize, validate
echo '<design-spec-json>' | bash "$SKILL/scripts/commit_design_spec.sh"
bash "$SKILL/scripts/create_versionless_project.sh" "$WS_DIR/<projectName>"
# Add --force to overwrite an existing project at that path:
bash "$SKILL/scripts/create_versionless_project.sh" --force "$WS_DIR/<projectName>"
# Then write src/main/mule/<projectName>.xml from the digest, then validate:
bash "$SKILL/scripts/validate_generated_flow_xml.sh" "$WS_DIR/<projectName>"

# Step 7 — render the canvas inline (Claude Desktop chat tab only)
# In the chat: render_mule_flow(project_dir="$WS_DIR/<projectName>")
# First-time install — preferred: build a .mcpb bundle and double-click it
# (one-time prereq: `npm i -g @anthropic-ai/mcpb`):
bash "$SKILL/scripts/build_mcpb.sh"          # → mcp/build/mule-flow-canvas-<v>.mcpb
open "$SKILL/mcp/build/mule-flow-canvas-"*.mcpb  # launches Claude Desktop install dialog
# Dev-loop fallback (live-edit via pip install -e, no .mcpb tooling needed):
bash "$SKILL/scripts/install_mcp_server.sh"

# RDS lifecycle
bash "$SKILL/scripts/ensure_rds.sh"                        # idempotent — bring up if not reachable
bash "$SKILL/scripts/start_real_rds.sh" --rebuild          # force WASM rebuild
bash "$SKILL/scripts/start_real_rds.sh" down               # stop the stack
```

| File | Purpose |
| --- | --- |
| `tmp/headless-env.json` | env probes (Node version, ACB presence) |
| `tmp/rds.json` | RDS endpoint + lifecycle state |
| `tmp/connector-choices/<nick>.json` | picked Go connector — prefix, namespace, schemaLocation, bundleSource |
| `tmp/connector-metadata/<nick>-digest.json` | rich digest used by the agent + validator |
| `tmp/connector-metadata/<nick>.json` | flat reference (operations / sources / configs / errorTypes) |
| `tmp/connector-metadata/<nick>-config.json` | per-config + connection-provider details |
| `tmp/connector-metadata/<nick>-<op>.json` | per-operation deep metadata |
| `tmp/connector-errors/<nick>.json` | connector-wide error-type whitelist |
| `tmp/design-spec.json` | committed design spec (Phase 2 input) |
| `<projectDir>/.mule/project.json` | workspace descriptor — `source` field gates `WorkspaceManagerImpl` |
| `<projectDir>/project-manifest.json` | name-only connector list |
| `<projectDir>/pom.xml` | stub; required until `WorkspaceManagerImpl` supports no-pom |
| `<projectDir>/mule-artifact.json` | runtime metadata |
| `<projectDir>/src/main/mule/<projectName>.xml` | flow XML (the agent writes this) |
| `<projectDir>/src/main/resources/config.yaml` | dot-keyed credentials placeholders |
| `$ACB_HOME/.cache/go/<name>/` | warm cache the ACB plugin reads on project-open |
