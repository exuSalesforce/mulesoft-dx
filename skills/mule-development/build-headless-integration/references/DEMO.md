# Demo runbook — `build-headless-integration`

> **Audience:** anyone showcasing the headless / versionless Mule design path end-to-end. Assumes a macOS workstation; Linux/Windows hosts work but have minor command differences (called out where relevant).
>
> **Story arc:** the user types a sentence → the agent picks Go connectors live from RDS → a versionless project lands on disk → the flow renders inline in Claude Desktop → "Test Connection" runs against the real RDS from inside the chat → the same project opens in ACB and Test Connection there proxies to the same RDS.
>
> **Total demo time:** ~10 minutes once prereqs are warm. ~25 minutes from cold (first RDS bring-up compiles WASM modules).

---

## What the audience sees

| Phase | Surface | What lands |
| --- | --- | --- |
| **1. Bring up the stack** | Terminal | RDS healthy at `:8090`, three connectors loaded (`salesforce`, `twilio`, `http`) |
| **2. Install the MCP App in Claude Desktop** | Claude Desktop install dialog | `mule-flow-canvas` in **Settings → Extensions**, two tools available: `render_mule_flow` + `test_connection` |
| **3. Generate the integration** | Claude Desktop chat | Project at `~/Salesforce/projects/headless/<projectName>/` — manifest-driven, no Maven, no anypoint-cli-v4 |
| **4. Render inline + test connection from chat** | Claude Desktop chat (canvas iframe) | Flow as React Flow nodes; Test Connection green for Salesforce |
| **5. Open in ACB** | VS Code with the dev-component extension | Same canvas, full nesting. Test Connection in ACB hits the same RDS at `:8090` |

---

## Prerequisites

These should all be true before the demo begins. Run the preflight at the bottom of this section if you're not sure.

| Need | Why | One-time setup |
| --- | --- | --- |
| `~/Salesforce/workspace/go-runtime/` checked out on `labs/rds` | RDS docker stack lives here | `git clone -b labs/rds … go-runtime` |
| `~/Salesforce/workspace/data-weave/go/` checked out on `labs/dw-golang` | Vendored sibling for `go mod vendor` | `git clone -b labs/dw-golang … data-weave` |
| Docker Desktop running | RDS + ConnectivityService containers | start Docker Desktop |
| `npm i -g @anthropic-ai/mcpb` | Builds the `.mcpb` artifact | one shell command |
| Claude Desktop installed and running | Runs the MCP server + iframes the canvas | App Store / claude.ai |
| ACB extension on `labs/design-service` (jar in `~/.vscode/extensions/...`) | Needs `ManifestRdsExtensionModelSource` to read `project-manifest.json` | rebuild + reinstall the dev-component VSIX |
| `MULE_DX_RDS_MODE=dev` and `MULE_DX_RDS_URL=http://localhost:8090` exported in launchd's `gui/<uid>` domain | macOS GUI apps don't read `~/.zshrc`; without these, ACB silently uses the prod stub | see `~/Library/LaunchAgents/com.<user>.mule-dev-envvars.plist` |
| Salesforce sandbox creds in launchd env (`SFDC_BASIC_USERNAME`, `SFDC_BASIC_PASSWORD`, `SFDC_BASIC_SECURITY_TOKEN`) | The Test Connection step needs real creds against a real org. **Salesforce alone is sufficient for Phase 4 + Phase 5** — the demo's Test Connection moments are against the Salesforce config. | same plist as above |
| (Optional) Twilio sandbox creds (`TWILIO_ACCOUNT_SID_AU`, `TWILIO_AUTH_TOKEN_AU`) | Only needed if you want to also Test Connection on the Twilio config. The flow itself renders + validates without them. | same plist as above |

### One-shot preflight

Run this in a terminal before the demo. Every line should print a green-ish answer:

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"

echo "===== docker ====="
docker info >/dev/null 2>&1 && echo "OK" || echo "FAIL — start Docker Desktop"

echo "===== RDS ====="
curl -fsS http://localhost:8090/healthz 2>/dev/null || \
  bash "$SKILL/scripts/ensure_rds.sh"

echo "===== RDS catalog ====="
curl -s http://localhost:8090/v1/connectors | jq -r '.connectors[]?.name'

echo "===== launchd env vars (must be visible to GUI apps) ====="
echo "MULE_DX_RDS_MODE = $(launchctl getenv MULE_DX_RDS_MODE)"
echo "MULE_DX_RDS_URL  = $(launchctl getenv MULE_DX_RDS_URL)"
echo "SFDC_BASIC_USERNAME = $(launchctl getenv SFDC_BASIC_USERNAME)"

echo "===== mcpb CLI ====="
which mcpb || echo "FAIL — npm i -g @anthropic-ai/mcpb"

echo "===== Claude Desktop running ====="
pgrep -fl "Claude.app/Contents/MacOS/Claude" | head -1 || echo "FAIL — launch Claude Desktop"

echo "===== ACB extension carries manifest-RDS support ====="
JAR=$(ls ~/.vscode/extensions/salesforce.mule-dx-mule-dev-component-*-SNAPSHOT/libs/*.jar 2>/dev/null | head -1)
if [[ -n "$JAR" ]] && unzip -p "$JAR" 2>/dev/null | strings | grep -q ManifestRdsExtensionModelSource; then
  echo "OK"
else
  echo "FAIL — rebuild + reinstall the dev-component VSIX from the labs/design-service branch"
fi
```

If any line says FAIL, fix it before the demo starts.

---

## Phase 1 — Bring up the stack (terminal, 1 min if warm; ~15 min cold)

Do this on your terminal before the demo so the audience doesn't watch a WASM build. The script is idempotent — calling it when RDS is already up is a no-op.

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"

bash "$SKILL/scripts/ensure_rds.sh"
```

After it prints `RDS is healthy at http://localhost:8090`, talk through what just happened:

1. **`go-runtime/start-rds.sh`** vendored the `data-weave/go` sibling, compiled `salesforce.wasm` / `twilio.wasm` / `http.wasm` from real connector source, and ran `docker compose up rds connector-service`.
2. **RDS** (`:8090`) speaks plain HTTP. `GET /v1/connectors` lists the three loaded modules; `GET /v1/connectors/<name>/descriptor` returns `extension-model.json` + `dsl.json` + `extension.xsd` atomically. `POST /v1/test-connection` runs a real connectivity check against the user-supplied credentials.
3. **ConnectivityService** (gRPC `:50051`) is what RDS delegates Test Connection to under the hood — it loads the `.wasm` module and runs the connector's real `testConnection` operation against the target system.
4. **Pre-warm the ACB cache** so the project-open path never blocks on RDS:

   ```bash
   bash "$SKILL/scripts/seed_cache.sh" --from-rds
   ls "$HOME/AnypointCodeBuilder/.cache/go/"   # → http  salesforce  twilio
   ```

Demo callout: *"This is the only checkout-time setup. Everything from here lives in the chat."*

---

## Phase 2 — Install the Mule Flow Canvas MCP App (Claude Desktop, 1 min)

Build and install the `.mcpb` once. Claude Desktop registers it as an MCP App under **Settings → Extensions**.

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"

bash "$SKILL/scripts/build_mcpb.sh"
open "$SKILL/mcp/build/mule-flow-canvas-"*.mcpb
```

Claude Desktop pops the install dialog. **Approve** → **Quit** (⌘Q) → **Relaunch**. MCP servers spawn at app start, and Claude Desktop only connects to the iframe pipeline once per app lifetime — no hot reload.

Demo callout: *"This is one MCP server, two tools — `render_mule_flow` to display the project's flow XML as a React Flow canvas, and `test_connection` to run the same RDS Test Connection the canvas would, but invokable from the chat."*

After relaunch, in **Settings → Extensions**, point at the `mule-flow-canvas` entry and the two tools. Talk briefly about how the bundle works:

- `manifest_version: "0.4"` with `server.type: "uv"` — Claude Desktop's bundled `uv` resolves the Python deps (mcp + lxml) into its own cache on first run. No Python install required on the user's machine.
- `uv.lock` ships inside the bundle so every user gets a deterministic resolved dep tree.

---

## Phase 3 — Generate the integration (Claude Desktop chat, 3–4 min)

Open a **new chat** in Claude Desktop. The skill is in `mulesoft-dx`, so it's auto-discovered if you've pointed Claude Desktop at the skills directory; otherwise paste the SKILL.md path on first message.

### Prompt 1 — kick off the design

```
I want to build a headless Mule integration that polls Salesforce for new
Account records every 30 seconds and sends an SMS notification via Twilio
to a sales-ops phone number. Use the headless / versionless / Go-connector
path so the project doesn't carry a Maven dependency for either connector.
```

The agent should:

1. Activate the `build-headless-integration` skill (you'll see "Skill is now active").
2. Phase 1, Step 1 — emit a Systems list (`salesforce`, `twilio`) and a trigger hint ("every 30 seconds").
3. Phase 1, Step 2 — run `phase1.sh sfdc:salesforce twilio:twilio`. **Watch the bash chip.** The script:
   - validates Node + jq + curl + ACB presence
   - probes `MULE_DX_RDS_URL/healthz` (or boots RDS if it's down)
   - calls `pick_connector.sh` → `fetch_bundle.sh` → resolves each connector's descriptor through the cache or RDS `/descriptor`
   - calls `describe_connector.sh` → emits the rich digest + per-shape files under `~/Salesforce/projects/headless/tmp/connector-metadata/`

   Demo callout: *"Phase 1 was 6+ separate bash chips before; one orchestrator script collapses them. Every artifact lands on disk so later steps can `jq` instead of relying on scrolled-past tool output."*

4. Phase 1, Step 3 — pick a trigger from the digest. Salesforce-Go has no native `<source>` for "new Account", and the user named a cadence ("every 30 seconds"), so the agent picks `<scheduler>` → `<salesforce:query>` (Rung 2 of the trigger ladder).
5. Phase 1, Step 4 — pick connection providers. Salesforce has three (`basic`, `jwt`, `saml`) → the agent should `AskUserQuestion`. Pick **basic**. Twilio has one (`account-sid-auth-token`) → the agent announces inline.
6. Phase 1, Step 5 — Technical Design Summary. Read it aloud, confirm:
   - Project name (typically `salesforce-poll-to-twilio` or similar)
   - Trigger: `<scheduler>` `<fixed-frequency frequency="30000"/>`
   - Connectors: `salesforce` (basic), `twilio` (account-sid)
   - Project layout: `.mule/project.json`, `project-manifest.json`, stub `pom.xml`, `mule-artifact.json`, flow XML, `config.yaml`
   - Connector descriptors NOT in the project — they live at `$ACB_HOME/.cache/go/<name>/`

### Prompt 2 — approve the design

```
Yes, proceed to build.
```

Phase 2 runs:

1. Step 6 — `commit_design_spec.sh` then `create_versionless_project.sh ~/Salesforce/projects/headless/<projectName>`.
2. Step 6 — agent writes `src/main/mule/<projectName>.xml` directly from the digest.
3. Step 6.5 — `validate_generated_flow_xml.sh` runs all six checks. Should print `flow XML validation passed (1 file(s))`.

Demo callout: *"Six validator checks — including the new per-element attribute coverage check that catches Java-vs-Go connector attribute drift. We had a real bug where the agent wrote `<salesforce:query salesforceQuery="...">` (Java connector attribute name) when the Go descriptor declared `soql`. Validator now catches it before the canvas does."*

Show the produced project on the terminal:

```bash
ls ~/Salesforce/projects/headless/<projectName>/
cat ~/Salesforce/projects/headless/<projectName>/.mule/project.json
cat ~/Salesforce/projects/headless/<projectName>/project-manifest.json
```

Point out:
- `.mule/project.json` carries `source: file:///.../pom.xml` — load-bearing field that gates `WorkspaceManagerImpl.initializeProjectFromExistingDescriptor`. Drop it and ACB hangs at `MuleClient registration timed out after 60000ms`.
- `project-manifest.json` carries the connector list as `{ "name": "salesforce" }`, `{ "name": "twilio" }` — name-only. The plugin's `ManifestRdsExtensionModelSource` reads this and pulls each descriptor from the warm cache.
- `pom.xml` is a stub — no connector dependencies. Goes away once `WorkspaceManagerImpl` learns the manifest path.

---

## Phase 4 — Render inline + test connection from the chat (Claude Desktop chat, 3 min)

### Prompt 3 — render the canvas

```
Render the flow at ~/Salesforce/projects/headless/<projectName>
```

The agent calls `render_mule_flow(project_dir="…")`. The chat shows an iframe with the React Flow canvas:

- Each top-level processor is one node (Scheduler → Salesforce Query → DataWeave Transform → Twilio Send SMS → Logger → Error Handler).
- Click any node — the right-hand side panel shows the XML attributes (`config-ref`, `soql`, `to`, `from`, `body`, etc.).
- Click on the `salesforce-config` node — the side panel shows the connection element with `${salesforce.basic.username}`, `${salesforce.basic.password}`, `${salesforce.basic.securityToken}` placeholders.

Demo callout: *"This is the inline-in-chat affordance. Same XML, same nodes ACB will show — but iframe-rendered through an MCP UI resource. Containers like `<choice>` / `<try>` collapse to summary nodes here; ACB shows the full nesting."*

### Prompt 4 — test the Salesforce connection from chat

```
Run a Test Connection on the Salesforce_Config in the project at
~/Salesforce/projects/headless/<projectName>
```

The agent calls `test_connection(project_dir="…", config_ref="Salesforce_Config")`. The tool:

1. Re-parses the project's flow XML to find `<salesforce:sfdc-config name="Salesforce_Config">` and its `<salesforce:basic>` child.
2. Reads `config.yaml` and resolves every `${...}` placeholder against env vars (the ones we set in launchd).
3. POSTs to `http://localhost:8090/v1/test-connection` with `{connector: "salesforce", providerName: "basic", fields: {username, password, securityToken}}`.
4. Prints the structured result — `{success: true, message: "...", configRef, connector, providerName, rdsUrl, fieldsSent: [...], fieldsOverridden: []}`. **No credential values are echoed back** — only field names.

Demo callout: *"Same RDS endpoint ACB will use when the user clicks Test Connection on the canvas. The MCP server is just a different surface to the same wire contract — `HttpRemoteDesignServiceClient.java` in the dev-component plugin and the MCP `_post_rds_test_connection` helper hit `/v1/test-connection` identically."*

### Optional — show a failing Test Connection

If you want to highlight error handling, run Test Connection with deliberately bad creds:

```
Run a Test Connection on the Salesforce_Config but override the password to "wrong-password"
```

The agent calls `test_connection(... overrides={"password": "wrong-password"})`. RDS responds with `{success: false, message: "..."}`. The structured result shows which field was overridden (only field name, not value).

---

## Phase 5 — Open the same project in ACB (1–2 min)

### From the terminal

```bash
code ~/Salesforce/projects/headless/<projectName>
```

(Or open VS Code → File → Open Folder → pick the project directory.)

What the audience sees:

1. **The flow renders in ACB's canvas.** Same nodes as in Claude Desktop, but with full nested layout — if the flow has a `<choice>` or `<try>`, ACB shows `<when>` / `<otherwise>` / `<error-handler>` as separate sub-nodes.
2. **Test Connection on the Salesforce config.** Click the `Salesforce_Config` node → "Test Connection" button in the side panel. **Watch the network tab if you want to be surgical** — ACB's plugin (`HttpRemoteDesignServiceClient.java`) POSTs to the **same** `http://localhost:8090/v1/test-connection`. RDS hands back the same `{success: true, message: "..."}`.
3. **The status indicator on the connector config goes green.**

Demo callout: *"Two surfaces, one contract. The MCP server's Test Connection tool and the ACB plugin's HttpRemoteDesignServiceClient both speak `/v1/test-connection`. The user picks where to test — chat for fast iteration, ACB for the full design surface — but the test runs against the exact same connectivity."*

### Common gotcha to call out

If ACB hangs at "MuleClient registration timed out after 60000ms" or shows red errors:

1. Check that `MULE_DX_RDS_MODE=dev` and `MULE_DX_RDS_URL=http://localhost:8090` are visible to **the GUI process** (not just `.zshrc`):

   ```bash
   launchctl getenv MULE_DX_RDS_MODE
   launchctl getenv MULE_DX_RDS_URL
   ```

   If they're empty, the launchd plist isn't exporting them. Reload it:

   ```bash
   launchctl bootout gui/$(id -u)/com.<user>.mule-dev-envvars 2>/dev/null
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<user>.mule-dev-envvars.plist
   launchctl kickstart -k gui/$(id -u)/com.<user>.mule-dev-envvars
   ```

   Then **fully quit VS Code** (⌘Q) and relaunch. The new env vars only reach a fresh process.

2. Check `~/AnypointCodeBuilder/logs/ACBLog-$(date +%Y-%m-%d).log` for the real stack trace — VS Code's devtools console shows symptoms; the JVM log shows root causes.

---

## Phase 6 — Wrap-up (1 min)

Summarize what just shipped on disk:

```bash
PROJECT="$HOME/Salesforce/projects/headless/<projectName>"
find "$PROJECT" -type f -not -path "*/target/*"
```

Six files, total < 5 KB:

- `.mule/project.json` — workspace descriptor
- `project-manifest.json` — name-only connector list
- `pom.xml` — empty stub (will go away)
- `mule-artifact.json` — `minMuleVersion` + `javaSpecificationVersions`
- `src/main/mule/<projectName>.xml` — the flow
- `src/main/resources/config.yaml` — credential placeholders

Three closing points:

1. **No Maven, no anypoint-cli-v4, no MTF.** The skill never shells out to any of them. Connectors are Go-bundled; descriptors are HTTP-fetched; Test Connection is HTTP-POSTed.
2. **Two install paths for the MCP server, your choice.** `.mcpb` for distribution (single-click install in Claude Desktop), `install_mcp_server.sh` for dev-loop edits (live `pip install -e`).
3. **Same RDS, same wire contract, two surfaces.** MCP tool from chat ↔ ACB canvas in VS Code. Both surfaces drive the same `/v1/test-connection` against the same Go-runtime stack.

---

## Reset between demos

```bash
SKILL="$HOME/Salesforce/workspace/mulesoft-dx/skills/mule-development/build-headless-integration"

# Wipe the generated project (uncomment the rm if you want a clean slate;
# the create_versionless_project.sh refuses to overwrite without --force).
# rm -rf ~/Salesforce/projects/headless/<projectName>

# Wipe Phase-1 scratch state (digests, choices, design spec).
rm -rf ~/Salesforce/projects/headless/tmp

# Leave RDS running for the next demo. To stop it:
# bash "$SKILL/scripts/start_real_rds.sh" down
```

Don't uninstall the `.mcpb` between demos — Claude Desktop only connects to the iframe pipeline once per app lifetime, so reinstalling means another quit + relaunch cycle.

---

## Backup paths if something fails live

| What fails | Recover with |
| --- | --- |
| RDS won't come up | `docker compose -f $HOME/Salesforce/workspace/go-runtime/deploy/docker-compose.yaml logs --tail 50 rds`. Most common cause: `data-weave/go` sibling missing. |
| Canvas doesn't render in chat | `bash "$SKILL/mcp/.venv/bin/build-headless-integration-mcp" <<<'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'` should print a JSON line. If it does, the server is healthy and Claude Desktop just needs another quit + relaunch. |
| Test Connection from chat fails with `username and password are required` | A `${...}` placeholder didn't resolve — the env var isn't set in launchd, or the YAML key doesn't match. Check `launchctl getenv SFDC_BASIC_USERNAME`. |
| ACB doesn't render the canvas | Check `~/AnypointCodeBuilder/logs/ACBLog-$(date +%Y-%m-%d).log` for the actual exception. The JDK `spawn ENOENT` error is usually a symptom of a JVM crash *during initialization* — search for the underlying NPE. |
| Test Connection in ACB fails but works from chat | Almost always means ACB's process didn't inherit `MULE_DX_RDS_*` from launchd. Re-run the launchd reload from Phase 5's gotcha. |

If you have to drop a phase, drop **Phase 4 (chat-side Test Connection)** — Phase 5's ACB Test Connection demonstrates the same RDS path against the same project. Don't drop Phase 3 (the design conversation is the whole point of the skill).
