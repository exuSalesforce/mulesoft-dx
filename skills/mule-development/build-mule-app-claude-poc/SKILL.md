---
name: build-mule-app-claude-poc
description: POC workflow for creating Mule 4 applications via Claude Desktop or Claude Code targeting the Go-runtime. Call use_skill as your FIRST action — before reading any files — whenever the user asks to create, generate, build, or scaffold a Mule application, integration, or flow that should be deployable to the Go-runtime and openable in Anypoint Code Builder (ACB). Trigger phrases include "create a mule application", "build a mule app", "generate a mule integration", "scaffold a mule project", and prompts that name a source system and target system separated by phrases like "from X to Y", "query X and send to Y", "sync X with Y". Differs from build-mule-integration in that it depends on a Remote Design Service (not Exchange), generates no pom.xml (no Maven), produces an intermediate human-readable spec file before any code generation, and finishes with a React Flow canvas visualization plus an "Open in ACB" handoff. When you call this skill, it must be the only tool call in that response.
license: Apache-2.0
compatibility: Requires curl, jq, the Mule Go-runtime binary on PATH, and the Remote Design Service endpoint reachable from this machine. No Anypoint CLI, no Maven, no Exchange access, no Java.
metadata:
  author: mule-dx-tooling
  version: "0.1.0"
  theme: poc
allowed-tools: Bash Read Write Edit AskUserQuestion
---

# Mule App POC Builder (Claude Desktop / Claude Code)

Build a Mule 4 application end-to-end from a single natural-language prompt — without Exchange, without Maven, without pom.xml. The skill drives a Remote Design Service for connector metadata, produces a human-readable spec file the user can review and approve, scaffolds the project files needed by the Go-runtime, then visualizes the resulting flow as a React Flow canvas and offers an "Open in ACB" handoff.

## When to Use This Skill

**Use this skill when the user asks to:**

- "Create a Mule application that queries Salesforce and sends SMS via Twilio"
- "Build a Mule app from <source system> to <target system>"
- "Generate a Mule project for the Go-runtime"
- "Scaffold a Mule integration I can open in ACB"

**Do NOT use this skill when:**

- The user is editing an existing Mule project's XML in place — that is `build-mule-integration` territory (it depends on Maven and Exchange).
- The user explicitly asks for a Maven build, a `pom.xml`, or an Exchange connector pin.
- The target runtime is the legacy JVM Mule runtime and not the Go-runtime.

**Trigger keywords:** create, build, generate, scaffold · mule app, mule application, mule integration, mule project, mule flow · go-runtime, go runtime, ACB, anypoint code builder · salesforce, twilio, slack, http, database (or any source/target pairing).

---

## Prerequisites

```bash
curl --version        # for the Remote Design Service calls
jq --version          # for parsing JSON responses
```

Environment variables this skill reads:

| Variable | Purpose | Default |
|---|---|---|
| `RDS_BASE_URL` | Base URL of the Remote Design Service. | `http://localhost:8090` |
| `RDS_AUTH_TOKEN` | Bearer token for the Remote Design Service. Optional in local dev. | _(empty)_ |
| `POC_PROJECT_DIR` | Where Phase 2 will write the generated project. | `./<project-name>` (cwd) |

If a required variable is missing the skill prompts the user once, persists the answer to `tmp/poc-env.json`, and re-uses it for the rest of the session.

---

## Bundled scripts

This skill ships small bash scripts under `scripts/`. Invoke them with the `Bash` tool — do not inline their contents. Every script writes its result to disk under `tmp/` so subsequent steps can read it back mechanically; this avoids the "the version vanished when the subshell exited" failure mode that plagued earlier iterations.

| Script | Purpose | Output location |
| --- | --- | --- |
| `scripts/check_env.sh` | Step 1 — verify `curl`, `jq`, the Remote Design Service is reachable (`GET /healthz` → `{"ready": true}`), and persist `RDS_BASE_URL` / `RDS_AUTH_TOKEN`. Validation-only. | `tmp/poc-env.json` |
| `scripts/list_connectors.sh [search]` | Step 3 — call `GET <RDS>/v1/connectors`, unwrap the `{"connectors": [...]}` envelope, and (optionally) filter client-side on the `name` field. Server-side filtering is not implemented by RDS. | `tmp/connectors-list.json` + stdout digest (`<name>  <ops-count>` per line) |
| `scripts/describe_connector.sh <connector-id> [<nickname>]` | Step 4 — call `GET <RDS>/v1/connectors/<id>/descriptor` and persist the full descriptor (`extensionModel` + `dsl` + `xsd`). The XSD is also written next to the JSON for the optional well-formedness check in Step 9. | `tmp/connector-metadata/<nickname>.json` + `<nickname>.xsd` + stdout digest |
| `scripts/describe_operation.sh <connector-id> <operation-name> [<nickname>]` | Step 5 — **local jq slice** of the cached descriptor. No RDS call — the descriptor already contains every operation's full schema. Combines `extensionModel.configurations[].operationModels[]` semantics with `dsl.operations.<op>` XML mapping. | `tmp/connector-metadata/<nickname>.<op>.json` |
| `scripts/write_spec.sh <spec-json>` | Step 7 — write the consolidated spec to disk in human-readable form (Markdown summary + JSON sidecar). | `tmp/spec/<project-name>.md` + `tmp/spec/<project-name>.json` |
| `scripts/scaffold_project.sh <spec-json>` | Step 9 — read the approved spec and create the project skeleton (project-artifact.json, src/main/mule/<name>.xml, src/main/resources/config.yaml, yaml/config.yaml, yaml/<flow>.yaml). Branches its trigger emission on `.trigger.type`. Default output dir is `~/projects/mule-poc-output/<project-name>` (override via `POC_PROJECT_DIR`). | `<POC_PROJECT_DIR>/...` |
| `scripts/xml_to_reactflow.sh <project-dir>` | Step 10 (optional) — translate `src/main/mule/<name>.xml` into a `{ nodes, edges }` JSON that React Flow consumes. The Pencil MCP rendering of this JSON is deferred — the JSON sidecar is ready to render whenever the canvas pipeline is wired up. | `tmp/reactflow/<project-name>.json` + stdout |

A seventh file, `scripts/_rds_lib.sh`, is a shared helper sourced by every script that talks to the Remote Design Service. **Do not invoke it directly** — its only public surface is the `rds_get <path> <out>` function used by the scripts above. The Remote Design Service contract it implements is documented in [`references/rds-api.md`](references/rds-api.md).

Invoke scripts by the absolute path you were given in the "skill is now active" message (the directory containing this `SKILL.md`). Do **not** construct relative paths like `../scripts/...` — Claude Desktop's working directory shifts across turns.

**Why scripts instead of inline curl:** Connector metadata is large (10s of KB per connector) and the JSON needs to survive multiple turns. Persisting to disk lets later steps `jq` the file at the call site instead of re-parsing scrolled-past tool output, which is where most "wrong attribute name" failures came from in the predecessor skill.

---

## Workflow shape (three phases)

This workflow has three phases separated by hard user-approval gates.

- **Phase 1: Discovery (Steps 1–6).** Identify source and target systems, call the Remote Design Service for connector metadata, ask the user to pick the operation and the connection details. Phase 1 writes only to `tmp/` — never to the user's project directory.
- **Phase 2: Spec & Approval (Step 7).** Consolidate the discovery findings into a single human-readable spec file, present a short summary, and wait for explicit user approval ("yes", "looks good", "proceed").
- **Phase 3: Generate (Steps 8–11).** Read the approved spec, scaffold the project files, render the React Flow canvas via the MCP App, and present the success message with the "Open in ACB" handoff.

Phase 2's approval gate is non-negotiable. Phase 3 must not start until the user has explicitly approved the spec — not the connector list, not the trigger choice, the **spec**.

## Workflow-wide discipline (read before Phase 1)

- **No project files before approval.** Steps 1–7 may write only to `tmp/`. The first write into the user's project directory happens in Step 9 (`scaffold_project.sh`) and only after Step 8 has confirmed approval.
- **No Maven, ever.** This skill never generates `pom.xml`, never adds Maven dependencies, and never invokes `mvn`. The Go-runtime resolves connector schemas at parse time from the bundled XML — there is no build step.
- **Connector metadata comes from the Remote Design Service, not from training-data memory.** Every operation name, attribute name, and child-element name in the generated XML must be backed by a `tmp/connector-metadata/*.json` file fetched in this session. If you cannot point at a JSON file on disk that contains the element you wrote, the element is hallucinated — delete it and re-fetch metadata.
- **One Remote Design Service call per response when discovering.** This keeps the user able to follow what the skill is doing and lets `AskUserQuestion` interleave naturally between fetches. Bundling four `describe_connector.sh` calls into one Bash invocation is forbidden during Phase 1.
- **Authentication assumption is fixed for this POC.** The skill only generates the connection-provider element the Remote Design Service describes. For the canonical connectors that resolves to: Twilio → Account SID + Auth Token (`username`/`password` on `<twilio:account-sid-auth-token-connection>`); HTTP listener → host/port. The Go-runtime Salesforce connector ships **without** any connection-provider metadata, so the scaffolder emits a bare `<salesforce:sfdc-config>` and the user wires credentials in `config.yaml` after opening in ACB. If the user explicitly asks for OAuth, JWT, or any other auth mechanism, stop and tell them this POC skill only handles whatever the RDS describes; redirect them to `build-mule-integration`.

- **Trigger is a user-input choice.** Step 2.5 always asks the user to pick HTTP listener vs Scheduler and persists the answer to `tmp/spec-inputs.json`. The scaffolder branches on `.trigger.type` and emits the matching template — `<http:listener>` for HTTP, `<scheduler><scheduling-strategy><fixed-frequency .../></scheduling-strategy></scheduler>` for Scheduler. Do not skip the question even when the user's prompt strongly implies one or the other; the user input is the source of truth.

---

# Phase 1: Discovery

## Step 1: Validate Environment

Run the environment check. It validates `curl`, `jq`, and that the Remote Design Service responds to `GET <RDS_BASE_URL>/healthz`. It persists the resolved `RDS_BASE_URL` and `RDS_AUTH_TOKEN` to `tmp/poc-env.json` for later steps.

```bash
bash <skill-dir>/scripts/check_env.sh
```

If the script exits non-zero, STOP. Do not proceed without a healthy Remote Design Service — every subsequent step depends on it. Surface the `errors` array from `tmp/poc-env.json` to the user verbatim.

If `RDS_BASE_URL` was not set in the environment, the script prompts the user once via `AskUserQuestion` (default `http://localhost:8090`) and writes the answer to `tmp/poc-env.json`.

---

## Step 2: Identify Source and Target Systems

In your response text (not a tool call), produce two records — these are plain prose so the user and Step 3 can read them:

**1. Systems list.** Identify the **EXACT system names** for source (where data comes from) and target (where data goes). Use specific names (Salesforce, Twilio, Slack, Database), NOT generic terms (CRM, SMS, chat). For the canonical POC prompt — "create a mule application that queries from top 5 Salesforce accounts and sends that information as a combined SMS via Twilio" — the systems list is:

- Source: Salesforce (Account object)
- Target: Twilio (SMS)

**2. Operation hints.** In one or two sentences, capture the verbatim phrases that name what the flow does — e.g. *"queries top 5 Salesforce accounts"*, *"sends a combined SMS"*. Do not classify yet — Step 4's metadata digest decides which connector operation matches.

Your next tool call after Step 2 MUST be Step 2.5's `AskUserQuestion` for the trigger choice. Do not skip ahead to `list_connectors.sh`.

---

## Step 2.5: Ask the User for the Trigger Type

Always ask the user — even when the prompt strongly implies one or the other:

```xml
<ask_followup_question>
<question>Which trigger should this Mule app use?</question>
<options>[
  "HTTP listener — exposes the flow at a POST endpoint you can hit with curl or from ACB",
  "Scheduler — runs the flow on a fixed-frequency cadence (every N seconds/minutes/hours)"
]</options>
</ask_followup_question>
```

**If the user picks HTTP listener,** ask the follow-up:

```xml
<ask_followup_question>
<question>What path and method should the HTTP listener accept?</question>
<options>[
  "POST /ops/<project-name> (recommended default)",
  "GET /ops/<project-name>",
  "POST /<custom path>",
  "Other"
]</options>
</ask_followup_question>
```

Persist the result into `tmp/spec-inputs.json` as:

```json
"trigger": {
  "type":   "http-listener",
  "method": "POST",
  "path":   "/ops/salesforce-accounts-to-twilio"
}
```

**If the user picks Scheduler,** ask the follow-up:

```xml
<ask_followup_question>
<question>How often should the scheduler fire?</question>
<options>[
  "Every 5 minutes (recommended default)",
  "Every 1 minute",
  "Every 1 hour",
  "Custom frequency"
]</options>
</ask_followup_question>
```

Persist into `tmp/spec-inputs.json` as (default `startDelay` is 0 unless the user asked otherwise):

```json
"trigger": {
  "type":               "scheduler",
  "schedulingStrategy": "fixed-frequency",
  "frequency":          5,
  "timeUnit":           "MINUTES",
  "startDelay":         0
}
```

The trigger choice is the **only** field of `tmp/spec-inputs.json` written before Step 3. Source / target / params get added later as they're collected.

---

## Step 3: List Connectors from the Remote Design Service

For each named system from Step 2 (source first, then target), run:

```bash
bash <skill-dir>/scripts/list_connectors.sh salesforce
```

The script writes the full JSON list to `tmp/connectors-list.json` and prints a digest to stdout, one connector per line:

```
salesforce            Salesforce Connector             salesforce
salesforce-analytics  Salesforce Analytics             salesforce-analytics
salesforce-marketing  Salesforce Marketing Cloud       salesforce-marketing
```

The columns are `<id> <name> <namespace>` — there is no version column because the Remote Design Service is versionless. The `id` slug is the only handle the next script needs.

**Decide & confirm.** Two cases:

- **Case A — one obvious match.** Acknowledge inline in one sentence and proceed to Step 4.
- **Case B — multiple plausible matches that are real variants of the same system.** Always escalate via `AskUserQuestion` with the actual connector IDs as the option labels. Never silently pick the first row when more than one row plausibly matches — the cost of one prompt is one turn; the cost of the wrong variant is a Phase-3 rewrite.

```xml
<ask_followup_question>
<question>The Remote Design Service returned multiple Salesforce connectors. Which should this app use?</question>
<options>[
  "salesforce — core Salesforce CRM connector with sObject query / DML operations",
  "salesforce-analytics — Salesforce Analytics (Wave) — datasets and dashboards",
  "salesforce-marketing — Salesforce Marketing Cloud (ExactTarget) — email and journeys"
]</options>
</ask_followup_question>
```

Repeat the same loop for the target system.

If the Remote Design Service returns zero matches for a named system, surface that to the user verbatim and ask whether to fall back to the generic HTTP connector or change the system name. Do not silently fall back.

---

## Step 4: Describe Connectors (overview)

For each connector chosen in Step 3, retrieve its full descriptor:

```bash
bash <skill-dir>/scripts/describe_connector.sh salesforce
bash <skill-dir>/scripts/describe_connector.sh twilio
```

The optional second arg is a **nickname** for the local filename — by default it equals the connector id, which is what the rest of the workflow expects. Override it (e.g., `describe_connector.sh salesforce sfdc`) only when two distinct connectors would otherwise collide on disk.

The script writes `tmp/connector-metadata/<nickname>.json` (the full RDS response: `extensionModel` + `dsl` + `xsd`), `tmp/connector-metadata/<nickname>.xsd` (extracted XSD), and prints a digest:

```json
{
  "name": "salesforce",
  "version": "11.4.0",
  "namespace_prefix": "salesforce",
  "namespace_uri":    "http://www.mulesoft.org/schema/mule/salesforce",
  "schema_location":  "http://www.mulesoft.org/schema/mule/salesforce/current/mule-salesforce.xsd",
  "configs": [
    { "name": "sfdc-config", "providers": [] }
  ],
  "operations_count": 8,
  "operations_sample": ["create", "delete", "describeSObject", "getUserInfo", "query", "retrieve", "update", "upsert"],
  "sources_count": 0,
  "sources_sample": [],
  "error_types": []
}
```

The `providers` list contains connection-provider *names* (e.g. `account-sid-auth-token`). It can be **empty** — the Go-runtime Salesforce connector ships without `connectionProviders`, in which case the scaffolder emits a bare `<salesforce:sfdc-config>` and the user wires credentials in `config.yaml` after opening in ACB.

**Read the digest.** It is the input to Steps 5 and 6 — which operation to call, which connection provider (if any) to wire up. The descriptor already includes the fully-expanded operation and connection-provider schemas, so Step 5 does not call the RDS again — `describe_operation.sh` is a local jq slice over the cached descriptor.

---

## Step 5: Pick the Operation (and Source, if needed)

The POC prompt almost always describes a request/response shape (HTTP endpoint → query source → transform → call target). For each connector in scope:

**For the source system,** identify the operation that retrieves data. For the canonical Salesforce prompt, the operation is `query` (SOQL). Run:

```bash
bash <skill-dir>/scripts/describe_operation.sh salesforce query
```

The script slices the cached descriptor and writes `tmp/connector-metadata/<nickname>.<op>.json` with a flat `attributes[]` array. Each entry carries `name`, `required`, `type`, `expressionSupport`, `defaultValue`, `asAttribute`, `asChild`, and `childElementName`. The scaffolder uses `asAttribute` / `asChild` to decide whether each parameter renders as an XML attribute or a nested child element. For both Salesforce `query` and Twilio `sendMessage`, every parameter is `asAttribute: true` — the operation element is flat with all parameters as attributes.

**For the target system,** identify the operation that sends/writes data. For the Go-runtime Twilio connector the SMS-send operation is `sendMessage` (camelCase). Run:

```bash
bash <skill-dir>/scripts/describe_operation.sh twilio sendMessage
```

**Trigger was already chosen in Step 2.5.** Do NOT re-ask the user; do NOT introspect `messageSources[]`. The trigger element is emitted by the scaffolder's template (`<http:listener>` or `<scheduler>`) — it is not metadata-driven for this POC. Event-source triggers (Salesforce object listeners, Kafka consumers, etc.) are out of scope; if the user explicitly asks for one of those at Step 2.5 or Step 5, stop and redirect them to `build-mule-integration`.

**Present operation choice to the user via `AskUserQuestion`** when the descriptor lists multiple operations that could plausibly satisfy the user's intent (e.g., Salesforce has `query`, `query-all`, `retrieve`, `search`). Use the `description` field from the descriptor as the human-readable subtitle:

```xml
<ask_followup_question>
<question>Which Salesforce operation should retrieve the top accounts?</question>
<options>[
  "query — execute a SOQL SELECT and return results (recommended)",
  "query-all — same as query but includes deleted records",
  "retrieve — fetch by record ID list (no SOQL)",
  "search — execute a SOSL search across multiple sObjects"
]</options>
</ask_followup_question>
```

When the choice is unambiguous (one obvious match), state it inline and skip the prompt.

---

## Step 6: Capture Operation Details

For each chosen operation, ask the user the small number of questions that determine the **values** that flow into the operation's required attributes — never ask about anything that the metadata already determined.

For the canonical POC:

- **Salesforce → query → SOQL.** Ask for the sObject and the limit. Default: `Account`, `5`. Always present this as `AskUserQuestion`:

```xml
<ask_followup_question>
<question>Which Salesforce object and how many records should the query retrieve?</question>
<options>[
  "Account — top 5 (default)",
  "Account — top 10",
  "Contact — top 5",
  "Opportunity — top 5"
]</options>
</ask_followup_question>
```

  Build the SOQL inline based on the answer: `SELECT Id, Name, Industry FROM Account LIMIT 5` — do not ask the user to type SOQL.

- **Twilio → sendMessage.** The descriptor lists `from`, `to`, `messageText`, `mediaUrl`, `accountSid` as parameters; `from` and `to` are required. Ask the user for the `from` (Twilio number) and `to` (recipient) phone numbers, plus the message body shape. The default body the POC uses is "Top N accounts:\n<comma-separated list of Name (Industry)>". **Do not** ask the user for their Twilio Account SID at this step — that is a credential handled in Step 12 via `config.yaml`.

Persist each answer to `tmp/spec-inputs.json` immediately so the spec writer in Step 7 can pick them up. The `trigger` block was already written in Step 2.5; you are merging in `source`, `target`, `summary`, and `projectName`:

```json
{
  "projectName": "salesforce-accounts-to-twilio",
  "summary": "Queries top N Salesforce accounts and sends a combined SMS via Twilio.",
  "trigger": {
    "type":   "http-listener",
    "method": "POST",
    "path":   "/ops/salesforce-accounts-to-twilio"
  },
  "source": {
    "connectorId": "salesforce",
    "nickname":    "salesforce",
    "config":      { "name": "salesforceConfig", "provider": "basic" },
    "operation":   "query",
    "params":      { "soql": "SELECT Id, Name, Industry FROM Account LIMIT 5" }
  },
  "target": {
    "connectorId": "twilio",
    "nickname":    "twilio",
    "config":      { "name": "twilioConfig", "provider": "account-sid-auth-token" },
    "operation":   "sendMessage",
    "params":      { "from": "+15555555555", "to": "+15105551212", "messageText": "Top {{count}} accounts: {{accountList}}" }
  }
}
```

The fields `connectorId` and `operation` MUST match strings the Remote Design Service returned in Steps 3–5. The `config.provider` MUST be one of the connection-provider names from the descriptor digest (e.g., `account-sid-auth-token` — write_spec.sh appends `-connection` to derive the actual XML element name). When the descriptor digest reports an empty `providers` array (e.g. for the Go-runtime Salesforce connector), set `config.provider` to `null` or omit it; the scaffolder will skip the provider sub-element in that case.

---

# Phase 2: Spec & Approval

## Step 7: Write the Spec File

Consolidate everything from Phase 1 into a single human-readable spec. Run:

```bash
bash <skill-dir>/scripts/write_spec.sh tmp/spec-inputs.json
```

The script reads `tmp/spec-inputs.json` and the connector metadata under `tmp/connector-metadata/`, then writes:

- `tmp/spec/<project-name>.md` — Markdown summary the user reads
- `tmp/spec/<project-name>.json` — JSON sidecar that Step 9's scaffolder consumes

The Markdown spec MUST contain, in this order:

1. **Project name** (kebab-case derived from the systems list — e.g. `salesforce-accounts-to-twilio`)
2. **What it does** — one sentence in plain English, derived from the user's original prompt
3. **Trigger** — element + endpoint or cadence (e.g. "HTTP listener at `POST /ops/salesforce-accounts-to-twilio`")
4. **Source** — connector + operation + the actual SOQL / parameters chosen in Step 6
5. **Transform** — DataWeave summary in plain English ("formats accounts into a Twilio SMS body")
6. **Target** — connector + operation + how the body is built
7. **Configuration the user must fill in after opening in ACB** — list of `config.yaml` keys (Salesforce username/password/securityToken/url, Twilio accountSid/authToken/fromNumber, http.host/http.port). The POC explicitly writes these as placeholders; the user fills them in via ACB's Connection panel and runs Test Connection.
8. **Files the scaffolder will create** — exact paths the scaffolder will write in Step 9.

Print the full Markdown spec inline in your response (so the user can read it without opening a file) **and** echo the file paths.

## Step 8: Get Spec Approval

Ask the user to approve the spec:

```xml
<ask_followup_question>
<question>Please review the spec above. Should I proceed and generate the project files?</question>
<options>[
  "Yes, looks good — generate the project.",
  "No, I want to change something — let me describe what.",
  "No, cancel."
]</options>
</ask_followup_question>
```

**[BLOCKER] WAIT for explicit approval before Step 9.** Acceptable approval phrases: "Yes, looks good", "yes proceed", "looks good", "go ahead". On any "No, I want to change something" outcome, ask which part (trigger, source, target, transform, config keys) and loop back to the relevant Phase 1 step. On "No, cancel", stop the workflow politely.

Once approved, the very first action of Step 9 is `scaffold_project.sh` — that is the script that promotes the approved spec into actual project files.

---

# Phase 3: Generate

## Step 9: Scaffold the Project

```bash
bash <skill-dir>/scripts/scaffold_project.sh tmp/spec/<project-name>.json
```

The scaffolder creates exactly the layout the bundled sample at `salesforce-accounts-to-twilio/` uses, **minus** the dot-directories, the `target/` build directory, the empty `services/` directory, the `mule-artifact.json` (Java is not in the loop for this POC), and the `pom.xml` (no Maven). It adds a new `project-artifact.json` in place of `mule-artifact.json` to capture connector source/target/metadata so downstream tooling and ACB can introspect the project without re-fetching from the Remote Design Service. The resulting tree is:

```
<POC_PROJECT_DIR>/
├── project-artifact.json
├── README.md
├── src/
│   └── main/
│       ├── mule/
│       │   └── <project-name>.xml
│       └── resources/
│           └── config.yaml
└── yaml/
    ├── config.yaml
    └── <project-name>-flow.yaml
```

The scaffolder synthesises every file from the approved spec:

- **`project-artifact.json`** — connector manifest for the project. Built by the scaffolder from `tmp/spec/<project-name>.json` (which already merges the relevant slices of `tmp/connector-metadata/*.json`). The manifest is **versionless** at the integration level — it carries no `groupId` or `assetId` — though the descriptor's connector `version` is preserved inside the namespace block so a future tool can correlate it. Shape:

  ```json
  {
    "projectName": "salesforce-accounts-to-twilio",
    "trigger": {
      "type":   "http-listener",
      "method": "POST",
      "path":   "/ops/salesforce-accounts-to-twilio"
    },
    "connectors": {
      "source": {
        "connectorId": "salesforce",
        "nickname":    "salesforce",
        "namespace":   { "prefix": "salesforce", "namespace": "http://www.mulesoft.org/schema/mule/salesforce", "schemaLocation": "..." },
        "config":      { "name": "salesforceConfig", "elementName": "sfdc-config", "provider": null },
        "operation":   "query",
        "connectionProvider": null,
        "operationSchema":    { "name": "query", "elementName": "query", "attributes": [ ... ] },
        "errorTypes": []
      },
      "target": {
        "connectorId": "twilio",
        "nickname":    "twilio",
        "namespace":   { "prefix": "twilio", "namespace": "http://www.mulesoft.org/schema/mule/twilio", "schemaLocation": "..." },
        "config":      { "name": "twilioConfig", "elementName": "config", "provider": "account-sid-auth-token" },
        "operation":   "sendMessage",
        "connectionProvider": { "name": "account-sid-auth-token", "elementName": "account-sid-auth-token-connection", "parameters": [ ... ] },
        "operationSchema":    { "name": "sendMessage", "elementName": "sendMessage", "attributes": [ ... ] },
        "errorTypes": [ ... ]
      }
    }
  }
  ```

  The `connectionProvider` and `operationSchema` blocks MUST contain the slices derived from the Remote Design Service descriptor in Steps 4–5 — verbatim, not paraphrased. Anything that does not appear in `tmp/connector-metadata/*.json` does not belong in `project-artifact.json`. `connectionProvider` is `null` when the connector ships without a provider (Go-runtime Salesforce). The trigger block carries `{type, method, path}` for HTTP listeners or `{type, schedulingStrategy, frequency, timeUnit, startDelay}` for the Scheduler.

- **`src/main/mule/<project-name>.xml`** — full flow XML built from connector metadata. Element names, attribute names, and child-element nesting come VERBATIM from `tmp/connector-metadata/*.json`. **Add `doc:name` and `doc:description` to every canvas-visible element** (flows, sources, operations, scopes, branches, global configs) — Step 10's React Flow canvas labels itself from `doc:description`.
- **`src/main/resources/config.yaml`** — `${ENV_VAR}` placeholders for credentials so ACB can wire them up.
- **`yaml/config.yaml`** — same shape but using `${dot.notation}` placeholders the Go-runtime expects.
- **`yaml/<project-name>-flow.yaml`** — the Go-runtime YAML representation of the flow (mirrors the bundled sample's `notify-accounts-sms-flow.yaml`).
- **`README.md`** — short README describing how to run the app on the Go-runtime and how to test it with `curl`.

**Authentication shapes (descriptor-driven):**

The scaffolder is metadata-driven — for every connector it reads the chosen `connectionProvider.elementName` from the descriptor, then emits one XML attribute per `required: true` parameter, each pointing at a `${<prefix>.<paramName>}` placeholder. For the canonical POC connectors that resolves to:

- Salesforce → bare `<salesforce:sfdc-config name="salesforceConfig"/>` (the Go-runtime Salesforce connector exposes no connection provider; user wires credentials in `config.yaml` after opening in ACB).
- Twilio → `<twilio:account-sid-auth-token-connection username="${twilio.username}" password="${twilio.password}" />` (Twilio's connection provider treats the Account SID and Auth Token as `username`/`password` — see `references/rds-api.md`).
- HTTP listener → `<http:listener-connection host="${http.host}" port="${http.port}" />` (template-driven — HTTP is not a descriptor-served connector).

Because every connector shape comes from the descriptor at scaffold time, swapping the source/target for a different connector "just works" — the scaffolder reads `connectionProvider.parameters[]` and emits whatever placeholders the new connector requires. If the user explicitly picks a non-basic-auth provider (OAuth, JWT), the skill still stops at Step 5 and redirects to `build-mule-integration` per the workflow-wide discipline.

---

## Step 10: Render the React Flow Canvas (optional)

> **POC scope:** Step 10 produces the React Flow `{ nodes, edges }` JSON sidecar but does **not** render the canvas. The Pencil MCP rendering pipeline isn't wired into this POC yet — the JSON is here so a future iteration can render it. Skip the actual rendering call and treat the success message in Step 11 as terminal.

Translate the generated XML into the `{ nodes, edges }` shape React Flow renders:

```bash
bash <skill-dir>/scripts/xml_to_reactflow.sh <POC_PROJECT_DIR>
```

The script parses `<POC_PROJECT_DIR>/src/main/mule/<project-name>.xml` and writes `tmp/reactflow/<project-name>.json` with the shape:

```json
{
  "nodes": [
    { "id": "n1", "type": "trigger",   "data": { "label": "HTTP POST /ops/...", "doc": "Receives POST requests..." }, "position": { "x": 0,   "y": 0 } },
    { "id": "n2", "type": "operation", "data": { "label": "Query Top Accounts", "doc": "Retrieves top Account records..." }, "position": { "x": 200, "y": 0 } },
    { "id": "n3", "type": "transform", "data": { "label": "Build SMS Payload",  "doc": "Formats accounts into a Twilio SMS body" }, "position": { "x": 400, "y": 0 } },
    { "id": "n4", "type": "operation", "data": { "label": "Send SMS via Twilio","doc": "Sends the account summary as an SMS"      }, "position": { "x": 600, "y": 0 } }
  ],
  "edges": [
    { "id": "e1-2", "source": "n1", "target": "n2" },
    { "id": "e2-3", "source": "n2", "target": "n3" },
    { "id": "e3-4", "source": "n3", "target": "n4" }
  ]
}
```

Translation rules the script applies:

- One node per element under `<flow>` that has a `doc:name` attribute (mirrors what the canvas shows in Studio / ACB).
- `data.label` = `doc:name`, `data.doc` = `doc:description`, `type` = element kind (`trigger`, `operation`, `transform`, `logger`, `choice`, `set-variable`, `error-handler`, …).
- `<choice>` and `<error-handler>` produce one parent node and child nodes for each `<when>` / `<otherwise>` / `<on-error-*>` branch, with edges fanning out and back in.
- Positions are laid out left-to-right at 200px increments per top-level step, with branches stacked vertically.

After the script runs, point the user at the JSON file path and move on to Step 11. The canvas rendering itself is deferred (see the note at the top of this step).

---

## Step 11: Success — Open in ACB

The completion message is short and ends with the "Open in ACB" handoff. Include exactly:

1. The project path: `<POC_PROJECT_DIR>`
2. One sentence naming the integration (derived from the spec's "What it does").
3. The `config.yaml` keys the user must fill in via ACB's Connection panel (verbatim from the spec).
4. A button-style call to action: `[Open in ACB](<acb-url-with-project-path>)`. The ACB URL scheme is `acb://open?path=<absolute-project-path>` — the scaffolder writes the resolved URL to `tmp/spec/<project-name>.acb-link.txt` so this step does not have to construct it from memory.
5. The `curl` one-liner the user can run after Test Connection passes:

```bash
curl -X POST http://localhost:8081/ops/salesforce-accounts-to-twilio \
  -H "Content-Type: application/json" \
  -d '{"limit": 5, "phoneNumber": "+15105551212"}'
```

Do **not** include marketing prose, "Features Implemented" recaps, or "Next Steps" lists beyond Test Connection + curl. The user can see the file tree and the React Flow canvas — the completion message is the handoff, not a summary.

---

## Best Practices

**1. Metadata-driven XML generation.** Never write `<connector:operation>` from memory. Always read it from `tmp/connector-metadata/<nickname>.<op>.json`:

- `attributes[]` → for each entry, decide attribute vs child element using `asAttribute` / `asChild` (both come from `dsl`); `name` is verbatim from the parameter model.
- Include every `required: true` parameter; emit `${<prefix>.<name>}` placeholders for required parameters when the spec didn't supply a literal value.
- Reference `config-ref` names that the scaffolder defined in the global configs.

**2. Authentication shapes are descriptor-driven.** The scaffolder emits whatever connection-provider element the descriptor describes (e.g. `<twilio:account-sid-auth-token-connection>`), and emits no provider element when the descriptor lists none (Go-runtime Salesforce). Do not surprise the user with OAuth, JWT, or mTLS flows that aren't in the descriptor. Anything else means escalating to `build-mule-integration`.

**3. Spec file is the contract.** Once the user approves the spec at Step 8, Step 9's scaffolder is purely mechanical — no new questions, no new metadata calls. If you find yourself wanting to ask the user something during Step 9, the right answer is to abandon Step 9, go back to Step 6/7, update the spec, and re-approve.

**4. React Flow is read-only.** The canvas in Step 10 is a visualization, not an editor. If the user says "change X" after seeing the canvas, treat it the same as "No, I want to change something" at Step 8 — go back to the relevant Phase 1 step, regenerate the spec, re-approve, re-scaffold, re-render.

**5. No `pom.xml`, no `mvn`.** The Go-runtime parses XML and YAML directly. Adding a `pom.xml` would imply a Maven build that the runtime never invokes; users have asked "why is there a pom.xml if I never run Maven?" in earlier POC iterations, which is what motivated removing it entirely.

---

## Troubleshooting

**Remote Design Service unreachable:** `bash <skill-dir>/scripts/check_env.sh` prints the resolved `RDS_BASE_URL` and the curl error. Fix the URL or start the service before retrying — every other step depends on it.

**Connector returned by `list_connectors.sh` but `describe_connector.sh` 404s:** the Go-runtime RDS catalog can include connectors that don't ship a descriptor — `http` is the canonical example (it appears in `/v1/connectors` but `/v1/connectors/http/descriptor` returns 404). For HTTP, the scaffolder uses a hand-written template instead. For other 404s, re-run `list_connectors.sh` to refresh the catalog and confirm the `name` field is what you're passing to `describe_connector.sh`.

**`xml_to_reactflow.sh` produces a node with empty label:** the corresponding XML element is missing `doc:name`. Fix it by re-scaffolding (Step 9 always emits `doc:name` on canvas-visible elements; a missing one means the scaffolder hit an unknown element kind it didn't have a template for).

**ACB does not open from the success-message link:** the `acb://` URL scheme requires ACB to be installed and registered. Fall back to "open ACB manually and import `<POC_PROJECT_DIR>` as an existing project."

**Test Connection fails for Salesforce:** the `url` field (login.salesforce.com vs test.salesforce.com) is the most common miss. The scaffolder writes `${salesforce.url}` as a placeholder; the user must set it explicitly in `config.yaml` before clicking Test Connection.

---

## Quick Reference

`<skill-dir>` below is the absolute path you were given in the "skill is now active" message. Use it consistently — do not construct relative `../scripts/...` paths.

```bash
# Step 1: validate environment + Remote Design Service reachability (GET /healthz → {"ready": true})
bash <skill-dir>/scripts/check_env.sh

# Step 3: list connectors (GET /v1/connectors), optionally client-side-filtered
bash <skill-dir>/scripts/list_connectors.sh salesforce
bash <skill-dir>/scripts/list_connectors.sh twilio

# Step 4: full descriptor (GET /v1/connectors/<id>/descriptor) → extensionModel + dsl + xsd
bash <skill-dir>/scripts/describe_connector.sh salesforce
bash <skill-dir>/scripts/describe_connector.sh twilio

# Step 5: per-operation slice (LOCAL — no RDS call)
bash <skill-dir>/scripts/describe_operation.sh salesforce query
bash <skill-dir>/scripts/describe_operation.sh twilio sendMessage

# Step 7: write the spec from collected inputs (Markdown + JSON sidecar)
bash <skill-dir>/scripts/write_spec.sh tmp/spec-inputs.json

# Step 9: scaffold the project from the approved spec
#         (default output dir: ~/projects/mule-poc-output/<project-name>)
bash <skill-dir>/scripts/scaffold_project.sh tmp/spec/<project-name>.json

# Step 10 (optional): translate the generated XML into a React Flow {nodes, edges} JSON
bash <skill-dir>/scripts/xml_to_reactflow.sh <POC_PROJECT_DIR>
```

---
