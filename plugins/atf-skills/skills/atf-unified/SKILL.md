---
name: atf-unified
version: 3.6.0
description: General-purpose ATF skill for any ServiceNow project. Covers server-side and UI testing via the now-sdk (Fluent), plus suite creation and scheduling. Auto-detects which path to use based on project structure and scope. Lean core + on-demand references; executed by the atf-tester subagent. Not project-specific — usable across HRSD, CSM, ITSM, custom scoped apps, and global scope.
author: SolvVision
tags: [development, testing, atf, automation, now-sdk, fluent, mcp, scoped-app, global, oob, hrsd, csm, itsm]
platforms: [claude-code]
tools:
  sdk:
    - npm run build
    - npm run deploy
    - npm run deploy -- --reinstall
  native:
    - Bash
    - Read
    - Edit
    - Write
  mcp:
    - query_records
    - create_record
    - create_scheduled_job
    - run_atf_test
    - run_atf_suite
    - get_atf_failure_insight
    - get_current_instance
    - get_current_update_set
    - switch_update_set
    - list_attachments
    - get_attachment_metadata
    - execute_background_script
complexity: intermediate
estimated_time: 15-45 minutes
---

# ATF Unified Skill — ServiceNow

The single ATF skill for any ServiceNow project. Covers server-side testing, UI/browser testing (catalog, form, navigation, Service Portal), suite creation, and scheduling. Auto-detects whether to use the SDK or MCP path.

**This file is the lean core** — path selection, the phase map, the Phase 6 self-heal contract, and the checklist. The bulk of the reference detail lives in on-demand files; read them as each phase needs them:

| Read when… | File |
|---|---|
| Authoring test steps (Phases 1–5, full `atf.*` catalog), MCP path, browser runner, hard limits, OOB, best practices | `references/sdk-api.md` |
| A build / deploy / run fails, or an assertion returns a wrong value | `references/troubleshooting.md` |
| Wiring tests into a suite + nightly schedule (Phase 7) | `references/suite-schedule.md` |

---

## Roles & Delegation

This skill is the **single source of truth for *how* to do ATF** — nothing else restates the loop or the
3-attempt rule (the global `~/.claude/CLAUDE.md` points here). Three layers cooperate:

- **Skill (`atf-unified`)** — the runbook. You are reading it.
- **Subagent (`atf-tester`)** — the **executor**. It follows this skill end-to-end in its own isolated
  context: preflight → author → build → deploy → run → self-heal (≤3 attempts/root cause) → write the
  `atf-reports/` audit report + download screenshots. **It MUST NOT prompt the user** — a subagent cannot
  ask mid-run. It ends by **returning a structured verdict** (`GREEN` / `BLOCKED` / `ERROR`).
- **Caller (the `/atf-verify` command or the main agent)** — owns the **human gate**. On a `BLOCKED`
  verdict it asks the user how to proceed: *continue self-healing / change approach / inspect the
  instance*, then re-delegates or stops.

**Entry points:** the `/atf-verify` command (manual front door) and an automatic **post-deploy hook**
that nudges a verification run after `npm run deploy`.

> If you are running this skill **interactively** (not as the `atf-tester` subagent), you play both roles:
> run the loop *and* ask the user directly at the gate.

---

## Phase 0 — Preflight (fail fast)

Before authoring or running anything, confirm the environment — silent misconfiguration is the most common
cause of wasted heal loops:

1. **Instance** — `mcp get_current_instance`; never assume which instance (PDI vs demo vs prod).
2. **Update set** — `mcp get_current_update_set`; it must match the artifact's app scope. `switch_update_set`
   if not. (SDK deploys bypass update-set capture if none is set.)
3. **ATF enabled** — if `run_atf_test` returns `ATF_NOT_ENABLED`, stop with an `ERROR` verdict (MCP config
   issue, not a test issue).
4. **Browser runner** (UI tests only) — a Client Test Runner tab must be open, or the Cloud Runner installed.

---

## Path Selection

Run these three checks before writing any test code. They determine which path applies.

### Check 1 — Does a now-sdk project exist?

```bash
cat package.json | grep '"@servicenow/sdk"'
ls src/fluent/
```

| Result | Path |
|---|---|
| Both exist | **SDK path** — full ATF coverage (server + UI) |
| Neither exists | **MCP path** — suite/scheduling only; steps must be authored in the ServiceNow ATF UI |

### Check 2 — What scope is the artifact in?

```
mcp query_records(table: 'sys_scope', query: 'scope=<artifact_scope>', fields: 'sys_id,name,scope')
```

| Scope | Recommended path |
|---|---|
| Custom scoped app (`x_<prefix>`) — now-sdk project | SDK path (write tests in `src/fluent/tests/`) |
| OOB module (`sn_hr_core`, `sn_csm`, `sn_incident`, etc.) | SDK path — test record lives in your scope, steps target the OOB table directly |
| Global | MCP path (suite/scheduling) + ATF UI (steps) |

### Check 3 — Do you need UI/browser steps?

The SDK fully supports UI steps via the `atf.catalog`, `atf.form`, `atf.catalog_SP`, `atf.form_SP`, and `atf.applicationNavigator` namespaces.

| Need | Path |
|---|---|
| UI/browser steps, SDK project exists | SDK path — write `atf.catalog` / `atf.form` steps directly |
| UI/browser steps, no SDK project | ServiceNow ATF UI (manual) — MCP cannot create UI steps |
| Server-side only | Either path works; SDK is preferred for any scoped app |

### Decision tree

```
Does a now-sdk project exist?
├── YES
│   ├── Server-side test → SDK path (atf.server.*)
│   ├── UI/browser test  → SDK path (atf.catalog, atf.form, etc.)
│   │                       Browser runner required to execute
│   └── Suite + schedule → SDK Record() on sys_atf_test_suite + sys_atf_test_suite_test
│                           + sysauto_script (version-controlled, survives --reinstall)
│
└── NO
    ├── Server-side test → SDK path (create a minimal now-sdk project targeting your scope)
    │                       OR write the test in the ServiceNow ATF UI
    ├── UI/browser test  → ServiceNow ATF UI (manual); MCP cannot create UI steps
    └── Suite + schedule → MCP — create_record on sys_atf_test_suite + create_scheduled_job
```

---

## The 7-Phase Flow

The SDK path runs seven phases. Phases 1–5 and 7 are detailed in the reference files; **Phase 6 (the
self-heal contract) is below, in full**, because it is the canonical behavior the subagent and `CLAUDE.md`
both anchor on.

| Phase | What it does | Detail |
|---|---|---|
| **1 — Read** | Read the artifact source + any existing test before writing; confirm it is `active` on the instance | `references/sdk-api.md` § Phase 1 |
| **2 — keys.ts** | Register every `sys_atf_test` / `sys_atf_step` ID in `keys.ts` before writing | `references/sdk-api.md` § Phase 2 |
| **3 — Author** | Write `Test()` steps — `atf.server.*`, `atf.catalog(_SP)`, `atf.form(_SP)`, `atf.applicationNavigator`, `atf.email`; chain step outputs | `references/sdk-api.md` § Phase 3 + Artifact→Test table |
| **4 — Build** | `npm run build`; verify one `sys_atf_test_*.xml` per test and one `sys_atf_step_*.xml` per step in `dist/app/` | `references/sdk-api.md` § Phase 4 |
| **5 — Deploy** | `npm run deploy` (`-- --reinstall` fallback) | `references/sdk-api.md` § Phase 5 |
| **6 — Run & Self-Heal** | Run, root-cause failures, fix, repeat ≤3×/root cause, **log every attempt to `atf-reports/`** | **below (core)** |
| **7 — Suite + Schedule** | Wire tests into a suite + nightly schedule via SDK `Record()` (preferred) or MCP (fallback) | `references/suite-schedule.md` |

For the MCP-only path (no SDK project), browser-runner setup, hard limits, OOB testing, and best
practices, see `references/sdk-api.md`.

---

## Phase 6 — Run & Self-Heal

**Trigger runs via the ServiceNow CI/CD API — the only verified headless mechanism.** ATF has no single-test run API and no `/api/now/atf/runner/*` endpoint (that path is fabricated and 404s). Runs are **suite-level**:

```
mcp run_atf_suite(sys_id: '<suite_sys_id>')   # → POST /api/sn_cicd/testsuite/run; returns a progress link to poll
```

- **Single test?** Wrap it in a one-test `sys_atf_test_suite` (Phase 7 `Record()`, or `create_record` on `sys_atf_test_suite` + `sys_atf_test_suite_test`), then run the suite. `run_atf_test` is **not** supported by the CI/CD API.
- **Headless reality:** a **server-side-only** suite (all `atf.server.*` steps) runs to completion with NO browser/runner. A suite containing any **UI step** needs a Client Test Runner tab open (`<instance>/atf_test_runner.do`) or those steps report `skipped` — see `references/sdk-api.md` § Browser Runner Requirements.
- **Read results from `sys_atf_test_result`** (`status`, `output`) — NOT `sys_atf_failure_insight` (that table does not exist OOB). Find them via `sys_atf_test_suite_result` (filter `test_suite=<suite_sys_id>`, newest) → `sys_atf_test_result` (filter `parent=<suite_result_sys_id>`), or query `sys_atf_test_result` by `test`=<id> ordered by `sys_created_on` desc.

**Direct REST (if the MCP run tool is unavailable on the instance):**
```
POST /api/sn_cicd/testsuite/run?test_suite_sys_id=<suite_sys_id>   (basic auth) → returns links.progress.url
GET  /api/sn_cicd/progress/<progress_id>                           → poll until percent_complete=100
GET  /api/now/table/sys_atf_test_result?sysparm_query=test=<id>^ORDERBYDESCsys_created_on   → status + output
```

**Fallback (no CI/CD plugin):** run from the ServiceNow UI — `sys_atf_test_suite.do?sys_id=<suite_sys_id>` → Run.

> **On PDIs and dev instances:** Prefer the UI's **Run Test Suite** button over MCP-triggering the scheduled job. `mcp trigger_scheduled_job` sets `next_action=now` but the background scheduler tick on PDIs is unreliable — waits of 90+ seconds with no execution are normal. The Run Test Suite button invokes the runner directly, without waiting for the scheduler.

**Self-healing loop (repeat until green) — OBSERVABLE:**

Every run of this loop MUST be logged to a persisted report file so the outcome is reviewable after the fact, not just scrolled-past chat. Do not run the loop "in your head."

**Report file:** create/append `atf-reports/<test-or-suite-name>-<run-date>.md` in the project root (create the `atf-reports/` dir if absent; `<run-date>` from the session date — do not invent timestamps). One file per test/suite per day; append each attempt as a new `### Attempt N` block.

**Per attempt:**

1. `mcp run_atf_suite(sys_id: '<suite_sys_id>')` (wrap a single test in a one-test suite) → poll the progress link to completion.
2. Read the failure detail from `sys_atf_test_result` (`status`, `output`) per test (filter `parent`=suite result, or `test`=<id> newest). `get_atf_failure_insight` is unreliable — its `sys_atf_failure_insight` table is often absent.
3. Identify exactly which assertion failed and the **actual vs expected** value.
4. **For UI-step failures, DOWNLOAD the screenshot** ServiceNow captured into the repo, so the report is a self-contained audit artifact:
   a. `mcp list_attachments(table_name: 'sys_atf_test_result', table_sys_id: '<result_sys_id>')` → find the PNG attachment(s); confirm with `mcp get_attachment_metadata`.
   b. Fetch the bytes via `mcp execute_background_script` — read the attachment with `GlideSysAttachment` and base64-encode it (read the input stream for the attachment sys_id, `GlideStringUtil.base64Encode` the bytes), then `gs.print` the base64 string.
   c. Decode the base64 and `Write` the image to `atf-reports/screenshots/<result_sys_id>-<step>.png`; link it from the report.
   **Fallback:** if the image is too large for a single background-script return, chunk it; if that is impractical, record the attachment sys_id + name in the report (link-only) and note the limitation.
5. Fix the source `.now.ts` file.
6. Rebuild → redeploy → re-run.
7. **Append an `### Attempt N` block to the report** (template below) before starting the next attempt.

**Attempt block template:**

```markdown
### Attempt N — <PASS | FAIL | BLOCKED>
- **Result sys_id:** <sys_atf_test_result sys_id>
- **Failed step / assertion:** <step name + assertion>
- **Expected:** <expected value>
- **Actual:** <actual value>
- **Screenshot:** <atf-reports/screenshots/<file>.png, or "n/a — server-side">
- **Root cause:** <one-line diagnosis>
- **Fix applied:** <file:line + what changed, or "none — see Blocked">
```

**Retry policy (explicit):** at most **3 attempts on the same root cause**. A new, distinct root cause resets the counter — note the root-cause change in the report so the count is auditable. Count is surfaced in the report, never implicit.

**When green:** append a final `## Result: GREEN` line with the passing result sys_id and total attempt count. Return a `GREEN` verdict to the caller.

**When irreparable (retries exhausted):** stop and emit a **structured blocked report** — do not silently give up or keep retrying. Append to the report file:

```markdown
## Result: BLOCKED
- **Test/Suite:** <name + sys_id>
- **Attempts:** 3 (limit reached on root cause: <root cause>)
- **Last expected vs actual:** <expected> / <actual>
- **Screenshot:** <atf-reports/screenshots/<file>.png, or n/a>
- **Fixes tried:** 1) … 2) … 3) …
- **Suspected blocker:** <platform constraint / data / scope / runner>
- **Needs from user:** <the specific decision or access required>
```

Then hand off per **Roles & Delegation**: if you are the `atf-tester` subagent, **RETURN the `BLOCKED` verdict — never prompt** (the caller runs the user gate). If you are running interactively, **ask the user** how to proceed — continue self-healing / change approach / inspect the instance. Do not report the task complete while a `BLOCKED` report stands.

---

## Checklist

Before reporting the task complete, every item must be true:

- [ ] Preflight passed: instance confirmed, update set scope matches the artifact, ATF enabled, browser runner available (UI tests)
- [ ] Path selection performed (SDK vs MCP) based on project structure and scope
- [ ] Artifact source read and understood before writing assertions
- [ ] No existing test duplicated
- [ ] All test and step IDs registered in `keys.ts` (SDK path)
- [ ] `npm run build` passes with no TestPlugin warnings
- [ ] `dist/app/` contains one `sys_atf_test_*.xml` per test and one `sys_atf_step_*.xml` per step
- [ ] Deploy succeeded
- [ ] Deployed artifact under test confirmed `active: true` on the instance before writing assertions
- [ ] Tests confirmed on instance via MCP query or UI check
- [ ] If impersonation used: test user granted minimum required roles via `sys_user_has_role` (`recordInsert` step, not `runServerSideScript`)
- [ ] For UI tests: a browser runner is available (Client Test Runner tab open or Cloud Runner plugin active)
- [ ] Tests passed, or exact failure reported with all fix attempts documented
- [ ] Run logged to `atf-reports/<name>-<date>.md` — one `### Attempt N` block per run, with expected vs actual and (for UI failures) the screenshot **downloaded** into `atf-reports/screenshots/`
- [ ] Final `## Result: GREEN` or structured `## Result: BLOCKED` block written; if BLOCKED, the verdict returned to the caller (subagent) or the user asked how to proceed (interactive)
- [ ] If applicable: suite created and scheduled

---

## References

- [ServiceNow SDK — Test()](https://docs.servicenow.com/csh?topicname=atf-test-now-ts.html&version=latest)
- [ATF Documentation](https://docs.servicenow.com/bundle/utah-application-development/page/administer/auto-test-framework/concept/automated-test-framework.html)
- [ATF Cloud Runner](https://docs.servicenow.com/bundle/utah-application-development/page/administer/auto-test-framework/concept/atf-cloud-runner.html)
- [now-sdk CLI reference](https://docs.servicenow.com/bundle/utah-application-development/page/build/servicenow-sdk/concept/sdk-overview.html)
