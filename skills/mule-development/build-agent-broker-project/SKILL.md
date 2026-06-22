---
name: build-agent-broker-project
description: "Build, edit, validate, publish, and deploy a MuleSoft Agent Broker (Agent Network V2) project end-to-end. Use whenever the user asks to build, create, scaffold, configure, edit, validate, publish, or deploy an Agent Broker, agent network V2, AgentScript, `.agent` file, or `agentNetwork: 2.0.0` project. Do NOT trigger for V1→V2 migration (use the converter skill)."
license: Apache-2.0
metadata:
  author: mulesoft-agent-broker-team
  version: "1.0.0"
---

# MuleSoft Agent Broker Builder

Turns a natural-language description of a multi-agent workflow into a complete, validated, deployable Agent Network V2 (GA, A2A v1.0) project. Runs a 6-phase guided experience and adds publish + deploy.

**The skill is CLI-first end-to-end.** Validate/publish/deploy use the **Anypoint CLI Agent Fabric plugin** (`mulesoft-anypoint-cli-agent-fabric-plugin`). Exchange asset search uses **Anypoint CLI v4** (`anypoint-cli-v4 exchange asset search`). Both are portable across Claude Code, Cursor, Codex, and Vibes, and match the CI/CD path. MCP tools (`mcp__mulesoft__*`) work as a fallback when present, but no MCP dependency is required.

## When to use

- Use for: building a new Agent Broker; adding/swapping nodes, agents, MCP tools, or LLMs; tuning instructions; changing routing; running validate/publish/deploy.
- Don't use for: V1→V2 conversions (use `translate-agent-broker-old-to-new-project`); standalone Mule apps, DataWeave, or APIs.

If the YAML has `schemaVersion: 1.0.0`, this is V1 — stop and route to the converter. The V2 marker is `agentNetwork: 2.0.0` (unquoted, top of file).

## References (read on demand)

- **`references/canonical-example.md`** — A complete, working Agent Network V2 (GA, A2A v1.0) project. The structural template — when in doubt, copy it.
- **`references/gotchas.md`** — GA syntax rules, compile-error rules, RULE-ASSET-MODE (inline vs Exchange), subagent-vs-orchestrator decision, auth casing, CLI + MCP tooling integration, graceful degradation.

The MuleSoft Agent Network GA docs (Anypoint Code Builder section) are the authoritative reference. The references above cover the gotchas and worked example.

## Tooling integration (CLI-first, MCP-fallback)

The skill prefers the **Anypoint CLI Agent Fabric plugin** (`mulesoft-anypoint-cli-agent-fabric-plugin`) for validate/publish/deploy and **Anypoint CLI v4** (`anypoint-cli-v4`) for Exchange search. The MuleSoft MCP server (`mcp__mulesoft__*`) is the fallback. **Detection order at each step:** (1) `command -v` the CLI; (2) check for the MCP tool; (3) graceful degradation.

See `references/gotchas.md` § "Tooling integration" for the full capability matrix, CLI command syntax, env-var auth (`ANYPOINT_CLIENT_ID/SECRET/ORG/ENV`), and graceful-degradation paths.

---

## Workflow A — Build a new project (Phases 1–6 + Publish/Deploy)

The 6 phases below structure the build experience. Each phase ends with a stop point — wait for the user. Apply each user response immediately (no batch-then-update).

## Step 1: Pre-flight + scaffold

1. **Detect existing project.** If working folder has `agent-network.yaml` + `exchange.json` + `brokers/`, ask: *"Edit this one, or scaffold new in a sibling folder?"* Default edit (Workflow B).
2. **Detect schema version.** `schemaVersion: 1.0.0` → route to converter.
3. **Confirm intent in one sentence:** *"You want me to build a new Agent Broker that does X. Sound right?"*
4. **Collect scaffold inputs** (ask before invoking CLI):
   - **Project name** (kebab-case, e.g. `it-help-investigation`) — also becomes the default `assetId`.
   - **Output directory** (default: current working dir).
   - **Asset version** (default `0.0.0` while in development; user can bump on first publish).
5. **Scaffold via CLI.** Run the create command from the parent directory:
   ```
   anypoint-cli-agent-fabric-plugin agent-network project create \
     --name <project-name> \
     --output-dir <parent-dir> \
     --create-dir
   ```
   This produces `<project-name>/agent-network.yaml` + `exchange.json` + `brokers/` with the correct `groupId`/`organizationId` (pulled from `ANYPOINT_ORG`) and starter template. Skill then edits the generated files in place.
   - If CLI is unavailable AND `mcp__mulesoft__create_agent_network_project` is present, call the MCP tool with the same inputs.
   - If neither is available, fall back to writing the canonical scaffold structure directly (`agent-network.yaml` with `agentNetwork: 2.0.0`, `exchange.json` with `"classifier": "agentic-network"`, empty `brokers/`) and tell the user the `groupId`/`organizationId` placeholder needs to be filled in before publish.
6. **Capture network `info`** for `agent-network.yaml`: ask for `info.label` (required) and `info.description` (optional). Default `info.version` to `1.0.0` unless user provides one. Apply to the scaffold immediately.

## Step 2: Functional Requirements (Phase 1 — be strict)

Make the user articulate what the broker *does* unambiguously. Do not proceed until requirements are concrete.

Capture (prompt until satisfied):

1. **Trigger:** What event starts this broker? (Almost always A2A `message/send`. Confirm.)
2. **Workflow steps and branching:** Walk me through each step. *"If X, then Y."*
3. **Hard constraints:** What is absolutely restricted? These become **router conditions**, not prompt sentences.
4. **Determinism vs open-ended:** Per step — predictable input → graph branching, or LLM judgment → LLM-powered node.
5. If user gives a vague answer twice in a row, accept as placeholder, flag, move on.

Stop. Summarize and confirm: *"Here's what I have: [...]. Anything missing?"* Stop.

After confirmation, **identify required assets**:
- **LLMs** (always at least one).
- **Tools** (external capabilities — list capabilities; choice of MCP vs A2A happens in Phase 2).

Present: *"Based on requirements, I've identified these asset needs: [list]. Confirm or adjust?"* Stop.

**Preview Exchange assets** for each capability. CLI-first:
- If `anypoint-cli-v4` is installed: run `anypoint-cli-v4 exchange asset search --search "<keywords>"` per capability and inspect results by name/description. The general CLI v4 `--type` flag accepts `connector`, `rest-api`, `soap-api`, `template`, `example`, `custom`, `raml-fragment` — but Agent Fabric–specific types (LLM/MCP/Agent) aren't first-class there yet, so search broadly and filter by asset name. **Always scope to the user's org** with `--organization <orgId>` to hit Private Exchange first; only widen to Public if no match.
- Else if MCP `search_asset` is available: call with `assetFilters: ["llm"]`, `["mcp"]`, `["agent"]` per capability — these *are* first-class in MCP-tool taxonomy.
- Else: ask the user for known `groupId`/`assetId`/`version` per asset; treat unknowns as inline placeholders.

Group results: *"Found in Exchange: [...]. Not found: [...]."* Save preview for Phase 2. Preview only — no file writes yet.

## Step 3: Asset Registration (Phase 2)

Register every required asset in `agent-network.yaml` and `exchange.json`. Sub-steps run sequentially. After each individual asset, ask "Add another?" before continuing.

**Each asset is in one of two modes** — see `references/gotchas.md` § "RULE-ASSET-MODE" for the full split. Short version:
- **Inline** (asset NOT in Exchange): registry entry + `context.connections` with `ref.name`.
- **Exchange** (asset already published): `exchange.json.dependencies` + `context.connections` with `ref.name` AND `ref.namespace`. **No registry entry.**

Auth always lives on `context.connections.<id>.authentication`. Parameterize URLs/secrets via `${<name>.url}` / `${<name>.apiKey}`. Add corresponding `exchange.json.metadata.variables`. Mark secrets `"secret": true`.

### 2a — LLM(s) (mandatory)

Inline schema: `info.label` required, `metadata.platform: Gemini | OpenAI | AzureOpenai`. Connection has `kind: llm` + `url` + `authentication`. Ask "Add another?"

### 2b — MCP server(s) (conditional)

Inline schema requires `info.label` and `metadata.transport.kind` (`streamableHttp` | `sse` | `stdio`).

After registering: ask the user **what `tool_name`** they intend to call (required for action definition). Ask if they know the input parameters. If yes, declare in action `inputs:`. If no, omit `inputs:` and the runtime auto-discovers. **Never fabricate tool names or input schemas.** Ask "Add another?"

### 2c — A2A agent(s) (conditional)

Inline schema requires `info.label` and an interfaces branch — `a2a` for current A2A v1.0 agents, `a2a_v03` for legacy A2A v0.3 agents (Agent Broker stays backward-compatible). The card under `metadata.interfaces.<branch>.card` includes `name`, `description`, `url`, `protocolVersion`, `version`, `capabilities`, `defaultInputModes`, `defaultOutputModes`, `skills`. See `references/gotchas.md` § "Registry agents" for the per-branch shape. Ask "Add another?"

## Step 4: Define the Broker (Phase 3 — Agent Script)

Write the structural skeleton of the `.agent` file. **Brief drafts** of `system.instructions` and `prompt`/`reasoning.instructions` only — Phase 5 refines prose.

Decisions:

1. **`agent_name`** — kebab-case (e.g. `it-help-investigation`). Also the `.agent` filename stem and broker id.
2. **Trigger.** Each broker has exactly one trigger per declared interface. `kind: "a2a"`, `target: "brokers://<broker-id>/a2a"`, `on_message:` is a fixed `transition to` (conditionals here are a compile error — use a router).
3. **Node decomposition.** Per workflow step:
   - Deterministic routing on a known value? → `router`.
   - Fixed side-effect (run one tool with known args, set a variable)? → `executor`.
   - Open-ended judgment, NO actions, NO HITL? → `generator`.
   - Open-ended judgment with actions OR HITL? → `subagent` (default LLM-powered type).
   - Coordinating MULTIPLE actions toward a compound goal? → `orchestrator`.
   - Final response to A2A client? → `echo` with `kind: "a2a:status_update_event"` (or `"a2a:artifact_update_event"` for artifacts).
4. **`subagent` is the default.** Use `orchestrator` ONLY for compound multi-action coordination. Single-action (even with A2A) → `subagent`.
5. **HITL is built into `subagent`.** When a subagent needs user input, the runtime auto-sends `input-required`. Do NOT model clarification as `subagent → router → executor → echo` — anti-pattern.
6. **Hard constraints from Phase 1 → router nodes, not prompts.** The constrained action goes in an `executor` gated by a `router`. Prompts can be ignored, router conditions cannot.
7. **First node after trigger should NOT be a pass-through executor** that copies `@request.payload.message`. Reference `@request.payload.message.parts[0].text` directly downstream.
8. **Edges.** Every non-terminal node has `on_exit: -> transition to @<nodeType>.<nodeId>`. Routers declare `routes:` + `otherwise:` and have NO `on_exit` (`transition to` inside router `on_exit` is a compile error).
9. **Echo terminus.** Every reachable path ends in `echo`. See `references/gotchas.md` § "Echo node" for the two `kind` values, the `TASK_STATE_*` enum, and the function-vs-reference rules for `a2a.*` helpers.

For full compile-error rules see `references/gotchas.md` § "Compile-error rules". For the structural template see `references/canonical-example.md`.

Update the `brokers` entry in `agent-network.yaml` to reference the new `.agent` file.

## Step 5: Asset Assignment to Graph (Phase 4)

Bind actions to nodes. Add an `actions:` entry per asset in the `.agent` file (A2A actions are `target` + `kind` only, no `inputs:`; MCP actions take `target`, `kind`, `tool_name`, optional `inputs:`). Reference from `reasoning.actions` (subagent/orchestrator) or `do: run` (executor).

For binding rules and cap/least-privilege guidance, see `references/gotchas.md`:
- **§ "Compile-error rules — action invocation"** — A2A bare reference vs `with message =` in executor; MCP `with` rules; `http_headers` implicit.
- **§ "Stage 4: Bind to nodes"** — 4-action cap, CR-18 least-privilege (irreversible mutations in `executor` + `router`, idempotent updates OK on orchestrator), LLM tier per node, action alias naming.

## Step 6: Instruction Refinement (Phase 5)

Make every LLM-powered node's prompt precise, testable, non-conflicting. **One node at a time, never batch.**

For each `generator`/`subagent`/`orchestrator`:

1. State which node: *"Refining `classifySeverity` (generator)."*
2. Show V1 prompt (brief draft from Phase 3).
3. Ask: *"What's your overall feedback? Any few-shot examples?"* Stop.
4. **Write V2:** rewrite as a numbered routine. Each step → one tool call or output decision. Avoid "be helpful"/"be professional".
5. **Make outputs concrete:** if the node has `outputs.properties.severity.enum`, the prompt must say *"Set severity to high when X, low otherwise"* matching the enum exactly.
6. **Anticipate edge cases:** what if a key field is missing? Bake the answer in.
7. **Per-node contradiction test:** does any prompt step get ruled out by deterministic graph?
8. Apply V2 to file immediately. Move to next node.

After all nodes refined: **cross-node contradiction test** — does any prompt conflict with another? Resolve with user.

## Step 7: Final Topology Review (Phase 6)

Cleanup, then validate.

**Cleanup:**
1. Remove unresolved `{{...}}` markers, unused `exchange.json` variables.
2. Remove unused `registry` assets (not referenced by `context.connections`, actions, or LLM blocks).
3. Remove unused `context.connections` entries.
4. Remove orphaned action definitions in `.agent` file.
5. Remove empty YAML keys (`registry.llms:` with no entries → drop the key).

**Validate.** Run the build command (CLI preferred → MCP fallback → structural checklist below + install hint). Full command syntax in `references/gotchas.md` § "Step 7 — Validate / build".

**Structural checklist:**
- Every node reachable from trigger? No orphans.
- Every reachable path terminates at `echo`?
- Every `router` has `routes` (≥1) and `otherwise`?
- Every `subagent`/`orchestrator` has `reasoning.instructions` AND ≥1 action OR HITL?
- Every action referenced in nodes matches an entry in `actions:`?
- Every `${...}` variable has matching `exchange.json.metadata.variables` entry?
- Every `context.connections.<id>.ref.name` resolves to a registry entry OR `exchange.json.dependencies`?
- All A2A actions in `reasoning.actions` are bare references (no `with message =`)?
- All MCP `with` parameters reference declared `inputs:` fields?
- All echo `state` values in the allowed enum?
- Hard constraints enforced via router conditions, not prompts?
- Operational caps set: `max_number_of_loops` lowered from default 25 (e.g., 3 classification, 5–10 orchestration); `task_timeout_secs` set if calling slow downstream agents?

**Fix loop:**
- Group errors by file. Auto-fix formatting/indentation/missing required keys. For schema-required references missing, ask the user — **never auto-insert missing assets**. Loop until clean.

When clean: *"Project is validated and ready. Want to publish to Exchange and deploy to runtime?"*

## Step 8: Publish (optional)

Only if user wants to. Prereqs: authenticated CLI/MCP context; `exchange.json` has `assetVersion` and no empty `default: ""` for `secret: true` variables.

Run the publish command (CLI preferred → MCP fallback → doc link). Surface published asset URLs from the output. Full command syntax is in `references/gotchas.md` § "Step 8 — Publish".

## Step 9: Deploy (optional)

Only if user wants to. Publish must have happened first.

Ask the user: `environmentName`, `targetSpace` (private space), and any deployment properties for env-specific secrets (e.g., `--property openai.apiKey:STAGING_API_KEY`).

**One-time setup per private space:** if the target space has no gateways yet, run the gateway setup command first.

Run the deploy command (CLI preferred → MCP fallback → doc link). Surface deployment URL/ID. Full command syntax, gateway defaults, and CI flags are in `references/gotchas.md` § "Step 9 — Deploy".

---

## Workflow B — Edit an existing project

**Universal edit principles:**

- **Impact analysis first.** Identify every downstream node, expression, or connection that depends on the change. Confirm with user.
- **Minimal disruption.** Edit only what's asked. Exception: node-type changes (subagent ↔ orchestrator) when actions are added/removed.
- **Registry-first.** New assets go in `agent-network.yaml` registry/context (or `exchange.json.dependencies`) BEFORE being referenced from `.agent`.
- **Defer validation while editing.** Lint errors mid-edit are expected; validate at the end.

### B.1 — Add or swap an asset

1. Decide mode (Inline or Exchange — see `gotchas.md`).
2. **Inline:** `registry.{agents,mcps,llms}` + `context.connections.<id>` with auth + `exchange.json.metadata.variables`. **Exchange:** `exchange.json.dependencies` + `context.connections.<id>` with `ref.name` + `ref.namespace`.
3. Add `actions:` entry in the `.agent` file.
4. Reference from target node's `reasoning.actions` (subagent/orchestrator) or `do: run` (executor).
5. **Re-evaluate node type if action count changed.** Single action → `subagent`. Multi-action → `orchestrator`. Update `@<oldType>.<id>` references downstream.
6. **Cap check.** If a node now exceeds 4 actions, propose splitting.
7. **Update `system.instructions`** to explain how to use the new asset.
8. Run Step 7 (validate).

### B.2 — Change graph logic

Edit `.agent`. After any change, walk trigger → every echo and confirm:
- Every router `when:` references a real, reachable upstream output (not `@request.payload` directly).
- Hard constraints still in router conditions, not prompts.
- No node became unreachable or dead-end.
- No `transition to` in a router's `on_exit` (compile error).

Run Step 7.

### B.3 — Refine instructions

Edit `.agent` only. Apply Phase 5 contradiction tests. If user pastes a policy doc, transform into numbered routine — don't paste verbatim. Run Step 7.

### B.4 — Add or change a connection policy

Edit `agent-network.yaml`. The GA schema supports policies even though the build flow doesn't surface them.

A policy has **two parts**:
1. **Definition** — `context.policies.<policyId>`.
2. **Binding** — referenced from `context.connections.<connId>.policies.outbound` or `brokers.<brokerId>.interfaces.a2a.policies.{inbound,outbound}`. Always reference by id.

For Exchange-published policies: add to `exchange.json.dependencies` first, then bind. Run Step 7.
