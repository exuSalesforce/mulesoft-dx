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
| `scripts/check_env.sh` | Step 1 — verify `curl`, `jq`, the Remote Design Service is reachable, and persist `RDS_BASE_URL` / `RDS_AUTH_TOKEN`. Validation-only. | `tmp/poc-env.json` |
| `scripts/list_connectors.sh [search]` | Step 3 — call `GET <RDS>/connectors?q=<search>` and write the full JSON list. Search term is optional; when omitted, returns the catalog. | `tmp/connectors-list.json` + stdout digest (one connector per line) |
| `scripts/describe_connector.sh <connector-id> [<nickname>]` | Step 4 — call `GET <RDS>/connectors/<id>` and persist the full descriptor (operations, sources, configs, attributes, child elements). | `tmp/connector-metadata/<nickname>.json` + stdout digest |
| `scripts/describe_operation.sh <connector-id> <operation-name> [<nickname>]` | Step 5 — call `GET <RDS>/connectors/<id>/operations/<op>` for one operation's full attribute and child-element schema. | `tmp/connector-metadata/<nickname>.<op>.json` |
| `scripts/write_spec.sh <spec-json>` | Step 7 — write the consolidated spec to disk in human-readable form (Markdown summary + JSON sidecar). | `tmp/spec/<project-name>.md` + `tmp/spec/<project-name>.json` |
| `scripts/scaffold_project.sh <spec-json>` | Step 9 — read the approved spec and create the project skeleton (project-artifact.json, src/main/mule/<name>.xml, src/main/resources/config.yaml, yaml/config.yaml, yaml/<flow>.yaml). | `<POC_PROJECT_DIR>/...` |
| `scripts/xml_to_reactflow.sh <project-dir>` | Step 10 — translate `src/main/mule/<name>.xml` into a `{ nodes, edges }` JSON that React Flow consumes. | `tmp/reactflow/<project-name>.json` + stdout |

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
- **Authentication assumption is fixed for this POC.** Salesforce uses **basic auth** (username + password + security token). Twilio uses **Account SID + Auth Token**. HTTP listener uses host/port. If the user explicitly asks for OAuth, JWT, or any other auth mechanism, stop and tell them this POC skill only handles basic-auth-style flows; redirect them to `build-mule-integration`.

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
- Trigger: HTTP listener (this POC always exposes the flow as an HTTP endpoint so the user can test it from ACB / `curl`)

**2. Operation hints.** In one or two sentences, capture the verbatim phrases that name what the flow does — e.g. *"queries top 5 Salesforce accounts"*, *"sends a combined SMS"*. Do not classify yet — Step 4's metadata digest decides which connector operation matches.

Your next tool call after Step 2 MUST be `list_connectors.sh` for the source system. Not `describe_connector.sh`, not `AskUserQuestion`. Step 3 is the non-negotiable next step.

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

The script writes `tmp/connector-metadata/<nickname>.json` (full JSON) and prints a digest:

```json
{
  "namespace_prefix": "salesforce",
  "configs": [
    { "name": "sfdc-config", "providers": ["basic", "oauth-jwt", "oauth-user-pass"] }
  ],
  "operations_count": 8,
  "operations_sample": ["query", "create", "update", "upsert", "delete"],
  "sources_count": 5,
  "sources_sample": ["deleted-object-listener", "modified-object-listener", "new-object-listener"],
  "error_types": ["MULE:ANY", "MULE:CONNECTIVITY", "SALESFORCE:CONNECTIVITY", "SALESFORCE:INVALID_INPUT"]
}
```

The digest has **no version field** — the Remote Design Service is versionless by contract (see `references/rds-api.md`). The `providers` list contains connection-provider *names* (e.g. `basic`), not element names; the descriptor's full `connectionProviders[]` array — including each provider's `elementName`, `attributes`, and `childElements` — is in the JSON file on disk.

**Read the digest.** It is the input to Steps 5 and 6 — which operation to call, which connection provider to wire up. Do not skip past the digest to a subsequent fetch. The descriptor already includes the fully-expanded connection-provider schema, so there is no follow-up "config-detail" call.

---

## Step 5: Pick the Operation (and Source, if needed)

The POC prompt almost always describes a request/response shape (HTTP endpoint → query source → transform → call target). For each connector in scope:

**For the source system,** identify the operation that retrieves data. For the canonical Salesforce prompt, the operation is `query` (SOQL). Run:

```bash
bash <skill-dir>/scripts/describe_operation.sh salesforce query
```

Read the response. It contains the full `attributes[]` and `childElements[]` schema — these become XML attributes and nested elements in Step 9.

**For the target system,** identify the operation that sends/writes data. For Twilio it is the message-creation operation (the actual element name comes from the descriptor — for the bundled connector it is `create20100401-accounts-messagesjson-by-account-sid`). Run:

```bash
bash <skill-dir>/scripts/describe_operation.sh twilio \
  create20100401-accounts-messagesjson-by-account-sid
```

**Trigger is fixed for this POC.** The trigger is always `<http:listener>` — Step 2 already established that this POC exposes the flow as an HTTP endpoint so the user can test it from ACB / `curl`. Do NOT call out to the Remote Design Service for connector sources; do not introspect `sources[]`. State the trigger choice inline: "Trigger: HTTP listener (POC default)." If the user's prompt explicitly asks for a cadence or event source ("every 5 minutes", "when an account is updated"), stop and tell them this POC skill is locked to HTTP-listener triggers; redirect them to `build-mule-integration`.

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

- **Twilio → send message.** Ask for the body shape. The default the POC uses is "Top N accounts:\n<comma-separated list of Name (Industry)>". For phone numbers, the spec defaults to placeholders — they are filled in via `config.yaml` after the project opens in ACB. **Do not** ask the user for their actual phone number or Twilio Account SID at this step — those are credentials handled in Step 12.

Persist each answer to `tmp/spec-inputs.json` immediately so the spec writer in Step 7 can pick them up:

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
    "operation":   "create20100401-accounts-messagesjson-by-account-sid",
    "params":      { "bodyTemplate": "Top {{count}} accounts:\\n{{accountList}}" }
  }
}
```

The fields `connectorId` and `operation` MUST match strings the Remote Design Service returned in Steps 3–5. The `config.provider` MUST be one of the connection-provider names from the descriptor digest (e.g., `basic`, not `basic-connection` — that latter value is the *element name* for XML emission, not the descriptor's provider name).

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

- **`project-artifact.json`** — connector manifest for the project. Built by the scaffolder from `tmp/spec/<project-name>.json` (which already merges the relevant slices of `tmp/connector-metadata/*.json`). The manifest is **versionless** — it carries no `version`, `groupId`, or `assetId` fields. Shape:

  ```json
  {
    "projectName": "salesforce-accounts-to-twilio",
    "connectors": {
      "source": {
        "connectorId": "salesforce",
        "nickname":    "salesforce",
        "namespace":   { "prefix": "salesforce", "namespace": "http://www.mulesoft.org/schema/mule/salesforce" },
        "config":      { "name": "salesforceConfig", "provider": "basic" },
        "operation":   "query",
        "connectionProvider": { "elementName": "basic-connection", "attributes": [ ... ], "childElements": [ ... ] },
        "operationSchema":    { "elementName": "query", "attributes": [ ... ], "childElements": [ ... ] },
        "errorTypes": [ "MULE:ANY", "SALESFORCE:CONNECTIVITY", ... ]
      },
      "target": {
        "connectorId": "twilio",
        "nickname":    "twilio",
        "namespace":   { "prefix": "twilio", "namespace": "http://www.mulesoft.org/schema/mule/twilio" },
        "config":      { "name": "twilioConfig", "provider": "account-sid-auth-token" },
        "operation":   "create20100401-accounts-messagesjson-by-account-sid",
        "connectionProvider": { "elementName": "account-sid-auth-token-connection", "attributes": [ ... ], "childElements": [ ... ] },
        "operationSchema":    { "elementName": "create20100401-accounts-messagesjson-by-account-sid", "attributes": [ ... ], "childElements": [ ... ] },
        "errorTypes": [ "MULE:ANY", "TWILIO:CONNECTIVITY", ... ]
      },
      "trigger": {
        "type":   "http-listener",
        "method": "POST",
        "path":   "/ops/salesforce-accounts-to-twilio"
      }
    }
  }
  ```

  The `connectionProvider` and `operationSchema` blocks MUST contain the `attributes[]` and `childElements[]` slices fetched from the Remote Design Service in Steps 4–5 — verbatim, not paraphrased. Anything that does not appear in `tmp/connector-metadata/*.json` does not belong in `project-artifact.json`. The trigger is fixed to HTTP listener for this POC, so it carries `{type, method, path}` only — no separate connector descriptor.

- **`src/main/mule/<project-name>.xml`** — full flow XML built from connector metadata. Element names, attribute names, and child-element nesting come VERBATIM from `tmp/connector-metadata/*.json`. **Add `doc:name` and `doc:description` to every canvas-visible element** (flows, sources, operations, scopes, branches, global configs) — Step 10's React Flow canvas labels itself from `doc:description`.
- **`src/main/resources/config.yaml`** — `${ENV_VAR}` placeholders for credentials so ACB can wire them up.
- **`yaml/config.yaml`** — same shape but using `${dot.notation}` placeholders the Go-runtime expects.
- **`yaml/<project-name>-flow.yaml`** — the Go-runtime YAML representation of the flow (mirrors the bundled sample's `notify-accounts-sms-flow.yaml`).
- **`README.md`** — short README describing how to run the app on the Go-runtime and how to test it with `curl`.

**Authentication shapes (POC-fixed):**

The scaffolder is metadata-driven — for every connector it reads the chosen `connectionProvider.elementName` from the descriptor, then emits one XML attribute per `required: true` attribute, each pointing at a `${<prefix>.<attributeName>}` placeholder. For the canonical POC connectors that resolves to:

- Salesforce → `<salesforce:basic-connection username="${salesforce.username}" password="${salesforce.password}" />` plus optional `securityToken` / `url` if present in the descriptor — basic auth ONLY for this POC.
- Twilio → `<twilio:account-sid-auth-token-connection username="${twilio.username}" password="${twilio.password}" />` (Twilio's connection provider treats the Account SID and Auth Token as `username`/`password` — see `references/rds-api.md`).
- HTTP listener → `<http:listener-connection host="${http.host}" port="${http.port}" />`.

Because every shape comes from the descriptor at scaffold time, swapping the source/target for a different connector "just works" — the scaffolder reads `connectionProvider.attributes[]` and emits whatever placeholders the new connector requires. If the user explicitly picks a non-basic-auth provider (OAuth, JWT), the skill still stops at Step 5 and redirects to `build-mule-integration` per the workflow-wide discipline.

---

## Step 10: Render the React Flow Canvas

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

After the script runs, render the canvas via the Pencil MCP App. The canvas is the user-facing visualization of the generated flow — show it inline in your response and reference the JSON file path so the user can re-render it.

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

- `attributes[]` → XML attributes on the operation element (use `attributeName` verbatim)
- `childElements[]` → nested XML elements (use `prefix:elementName`)
- Include every `required: true` attribute and child element
- Generate child elements in the exact order of the `childElements[]` array — XSD enforces sequencing
- Reference `config-ref` names that the scaffolder defined in the global configs

**2. Fixed authentication shapes for the POC.** Do not surprise the user with OAuth, JWT, mTLS, or session-token flows. The POC is locked to basic auth (Salesforce), Account SID + Auth Token (Twilio), and unauthenticated HTTP listener. Anything else means escalating to `build-mule-integration`.

**3. Spec file is the contract.** Once the user approves the spec at Step 8, Step 9's scaffolder is purely mechanical — no new questions, no new metadata calls. If you find yourself wanting to ask the user something during Step 9, the right answer is to abandon Step 9, go back to Step 6/7, update the spec, and re-approve.

**4. React Flow is read-only.** The canvas in Step 10 is a visualization, not an editor. If the user says "change X" after seeing the canvas, treat it the same as "No, I want to change something" at Step 8 — go back to the relevant Phase 1 step, regenerate the spec, re-approve, re-scaffold, re-render.

**5. No `pom.xml`, no `mvn`.** The Go-runtime parses XML and YAML directly. Adding a `pom.xml` would imply a Maven build that the runtime never invokes; users have asked "why is there a pom.xml if I never run Maven?" in earlier POC iterations, which is what motivated removing it entirely.

---

## Troubleshooting

**Remote Design Service unreachable:** `bash <skill-dir>/scripts/check_env.sh` prints the resolved `RDS_BASE_URL` and the curl error. Fix the URL or start the service before retrying — every other step depends on it.

**Connector returned by `list_connectors.sh` but `describe_connector.sh` 404s:** under the versionless RDS contract every connector is addressed by its `id` slug. If a 404 happens, the most likely cause is that the local `tmp/connectors-list.json` is stale — re-run `list_connectors.sh` to refresh it and pass the `id` field (not the human-readable `name`) to `describe_connector.sh`.

**`xml_to_reactflow.sh` produces a node with empty label:** the corresponding XML element is missing `doc:name`. Fix it by re-scaffolding (Step 9 always emits `doc:name` on canvas-visible elements; a missing one means the scaffolder hit an unknown element kind it didn't have a template for).

**ACB does not open from the success-message link:** the `acb://` URL scheme requires ACB to be installed and registered. Fall back to "open ACB manually and import `<POC_PROJECT_DIR>` as an existing project."

**Test Connection fails for Salesforce:** the `url` field (login.salesforce.com vs test.salesforce.com) is the most common miss. The scaffolder writes `${salesforce.url}` as a placeholder; the user must set it explicitly in `config.yaml` before clicking Test Connection.

---

## Quick Reference

`<skill-dir>` below is the absolute path you were given in the "skill is now active" message. Use it consistently — do not construct relative `../scripts/...` paths.

```bash
# Step 1: validate environment + Remote Design Service reachability
bash <skill-dir>/scripts/check_env.sh

# Step 3: list connectors for a system (writes tmp/connectors-list.json + stdout digest)
bash <skill-dir>/scripts/list_connectors.sh salesforce
bash <skill-dir>/scripts/list_connectors.sh twilio

# Step 4: full descriptor for a chosen connector (id from list output)
bash <skill-dir>/scripts/describe_connector.sh salesforce
bash <skill-dir>/scripts/describe_connector.sh twilio

# Step 5: full schema for an operation
bash <skill-dir>/scripts/describe_operation.sh salesforce query
bash <skill-dir>/scripts/describe_operation.sh twilio \
    create20100401-accounts-messagesjson-by-account-sid

# Step 7: write the spec from collected inputs (Markdown + JSON sidecar)
bash <skill-dir>/scripts/write_spec.sh tmp/spec-inputs.json

# Step 9: scaffold the project from the approved spec
bash <skill-dir>/scripts/scaffold_project.sh tmp/spec/<project-name>.json

# Step 10: translate the generated XML into a React Flow {nodes, edges} JSON
bash <skill-dir>/scripts/xml_to_reactflow.sh <POC_PROJECT_DIR>
```

---
