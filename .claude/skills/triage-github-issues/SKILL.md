---
name: triage-github-issues
description: Use when triaging new GitHub issues in this repo — analyzes each issue, attempts reproduction, drafts a Salesforce GUS work item (bug), and awaits confirmation before creating. Accepts a since date or issue number. Works manually or from a schedule.
---

# Triage GitHub Issues — mulesoft/mulesoft-dx

## Inputs (provided by caller or inferred)

| Parameter | How to supply | Default |
|-----------|--------------|---------|
| `SINCE` | "since 2026-06-18T10:00:00Z" | 24 hours ago |
| `ISSUE_NUMBER` | "triage issue #135" | — all new issues |
| `SLACK_CHANNEL` | "post to #leandro-cu-bot" | no Slack |

## Step 1 — Find issues

**Single issue:** skip discovery, go to Step 2.

**Bulk triage:** fetch open issues since `SINCE` (default: 24h ago):

```bash
# macOS/BSD:
SINCE="${SINCE:-$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)}"
# Linux fallback:
SINCE="${SINCE:-$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)}"

gh issue list \
  --repo mulesoft/mulesoft-dx \
  --state open \
  --json number,title,body,createdAt,url,labels,author \
  --jq "[.[] | select(.createdAt > \"$SINCE\")]"
```

If no issues: report "No new issues since $SINCE." and exit.

## Step 2 — Dedup check against GUS

Before analyzing, check if a GUS bug already exists:

```bash
sf data query --target-org gus \
  --query "SELECT Id, Name FROM ADM_Work__c WHERE Name LIKE '%#<NUMBER>%' LIMIT 1" \
  --json
```

If found: skip this issue silently, move to next.

## Step 3 — Analyze and attempt reproduction

```bash
git checkout master && git pull
```

For each issue:

**3a. Understand:**
- Reported vs expected behavior
- Steps to reproduce
- Affected area: `[UI]`, `[API]`, `[Dev Portal]`, `[Infra]`

**3b. Attempt reproduction:**
- Find relevant code paths in the repo
- Run portal generator if relevant: `make generate-portal BASE_URL=http://localhost:8080`
- Run tests if relevant: `make test-portal`
- Check recent commits: `git log --oneline -20`

**3c. Assess reproducibility:**
- **Confirmed** — found the code path, can explain exactly why
- **Plausible** — mechanism makes sense but can't fully verify without running the app
- **Cannot reproduce** — unclear, missing context, or unrelated to this repo

If **Cannot reproduce**: skip GUS draft, note the reason.

## Step 4 — Draft GUS bug

For Confirmed or Plausible issues:

```
Subject: [<area>] <concise title> (GH#<number>)
Type: Bug
Epic: Mulesoft Dev Portal - Post GA
Points: <1-5>
Assignee: <YOUR_NAME>

Steps to reproduce: <from issue or inferred>
Expected: <from issue>
Actual: <from issue>
Notes: <code path, related commit, etc.>
```

## Step 5 — Confirm before creating

**If SLACK_CHANNEL is provided:** post one message per issue to that channel:

```
*New GitHub Issue #<number>* — <title>
<url>
Reported by: <author> | Reproducibility: <Confirmed/Plausible>

*Draft GUS bug:*
> Subject: [<area>] <title> (GH#<number>)
> Epic: Post GA | Points: <N>
> Steps: <summary>
> Expected: <expected>
> Actual: <actual>

Create this GUS bug? Reply *yes* or *no* in this thread.
```

Wait for reply. On **yes** → Step 6. On **no** → "Ok, skipped."

**If no SLACK_CHANNEL:** show the draft in the session output and ask the user directly.

## Step 6 — Create GUS bug

Use the `gus-devportal-wi` skill to create the bug with the drafted details.

After creation, report:
```
✅ Creado: <W-number> — <title>
<GUS URL>
```

If Slack: reply in the same thread with the W-number and GUS URL.

## Notes

- Never create a GUS work item without explicit confirmation
- One thread/message per issue — don't batch multiple issues in one message
- Always restore repo to master after analysis
