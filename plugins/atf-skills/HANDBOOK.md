# ATF Testing Handbook — for New Colleagues

Welcome. This is the **`atf-skills`** plugin: it lets Claude Code **author, deploy, run, and self-heal**
ServiceNow ATF (Automated Test Framework) tests for you, then hand back a pass/fail verdict and an audit
report. It works on **any** ServiceNow SDK (Fluent / now-sdk) project and **any** instance — nothing in it
is tied to a specific app.

Read this once before your first ATF run. It takes ~10 minutes and saves you a lot of guessing.

---

## 1. What you get

| Piece | What it is | You touch it… |
|---|---|---|
| **Skill** `atf-unified` | The runbook Claude follows (how to write/build/deploy/run/heal ATF) | never directly |
| **Subagent** `atf-tester` | The worker that runs the whole loop in its own context and returns a verdict | never directly |
| **Command** `/atf-verify` | Your front door — point it at an artifact | **yes — you type this** |
| **Hook** (post-deploy) | After `npm run deploy`, nudges Claude to verify automatically | automatic |

You mostly just **prompt Claude**; the harness does the rest.

---

## 2. Install / enable the plugin

It's published in the SolvVision marketplace (`CountessGrafe/servicenow`). In Claude Code:

```
/plugin            → add marketplace CountessGrafe/servicenow (if not already)
                   → enable the "atf-skills" plugin
```

Confirm it loaded — you should see the `/atf-verify` command and an `atf-tester` agent. Reload the
window/session if they don't appear yet.

---

## 3. One-time setup on YOUR instance

The plugin is ready; your **instance + MCP** need to be wired up. Ask Claude:
> "Confirm my ServiceNow instance + update set, that ATF is enabled, and that `run_atf_suite` works."

Checklist:

1. **A now-sdk project** (has `now.config.json` + `src/fluent/`). Authoring ATF tests needs this. The
   test files live in *your* project under `src/fluent/tests/` — the plugin ships none.
2. **MCP server connected** (`servicenow-mcp` or `nowaikit`) pointed at your instance, with
   `WRITE_ENABLED=true` and `ATF_ENABLED=true`.
3. **ATF enabled on the instance** — `sn_atf.runner.enabled=true` (usually already on).
4. **The run trigger works** — see §4. This is the one piece people get stuck on.
5. **Right update set** — must match your app's scope before you deploy. Claude will check; switch if not.

---

## 4. How runs are triggered (important — read this)

ServiceNow has **no single-test run API** and **no `/api/now/atf/runner/*` endpoint** (that path is a myth —
it 404s). The real, supported, headless trigger is the **CI/CD API**, and it works at the **suite** level:

```
POST /api/sn_cicd/testsuite/run?test_suite_sys_id=<id>   → returns a progress link
GET  /api/sn_cicd/progress/<id>                          → poll until 100%
read sys_atf_test_result (status, output)                → pass/fail + diagnostics
```

In this setup the MCP tool **`run_atf_suite`** calls that endpoint for you. Two things to verify on your env:

- **Your MCP `run_atf_suite` must call `/api/sn_cicd/testsuite/run`.** Stock copies of some MCP servers
  hardcode the fake `/api/now/atf/runner/run_suite` and will 404. If `run_atf_suite` errors with "URI does
  not represent any resource," your MCP needs the one-line fix (point it at `sn_cicd`) — ask Claude to
  patch it, or call the REST endpoint directly with your instance creds.
- **The `sn_cicd` (CI/CD) feature must be active** on the instance and your user needs `sn_cicd`/admin
  rights. Quick check: a `POST /api/sn_cicd/testsuite/run` with no params should return a *CI/CD error*
  ("Missing parameter…"), not a 404.

### Headless vs. browser — the rule that decides your day
| Test type | Runs headless? | What you do |
|---|---|---|
| **Server-side only** (all `atf.server.*` steps) | ✅ fully autonomous | nothing |
| **Any UI/browser step** (`atf.catalog`, `atf.form`, portal) | ❌ needs a runner | keep a **Client Test Runner** tab open: `https://<your-instance>/atf_test_runner.do` |

The paid Cloud Runner (which would make UI tests headless too) is **not** available on PDIs — so for UI
tests on a dev instance, the browser tab is the only option.

---

## 5. Daily workflow

1. **Build + deploy your artifact** (`npm run deploy`). The post-deploy hook nudges a verification.
2. **Or trigger it yourself:**
   ```
   /atf-verify <YourArtifactName>
   ```
   or in natural language with context (better assertions):
   > "Create and run ATF tests for the **<YourArtifact>** and assert <what it should produce>. Clean up
   > test data afterward. Server-side/headless if possible."
3. **Claude (via `atf-tester`) does:** read artifact → author `Test()` steps → build → deploy → wrap in a
   suite → run via `sn_cicd` → poll → read results → **self-heal up to 3 attempts per root cause** →
   return **GREEN / BLOCKED / ERROR**, logging every attempt to `atf-reports/<name>-<date>.md`.
4. **If BLOCKED**, Claude asks you one question: *continue self-healing / change approach / I'll inspect
   the instance.*
5. **Result:** a verdict in chat + an audit file under your project's `atf-reports/`.

---

## 6. Worked example — a catalog item with a flow behind it

Scenario: you built a catalog item whose **fulfillment flow** creates a record on submit.

**Prompt:**
> "Create and run a **server-side E2E** ATF test for the **<YourCatalogItem>** catalog item and its
> fulfillment flow. It should: create a test user, impersonate them, submit the item, **wait for the flow
> to create the record in `<output_table>`**, then assert `<field_a>`, `<field_b>`, and `submitted_by`.
> Clean up afterward."

Two things to know about catalog-item-plus-flow tests:

- **Flows are async** — the test must *poll* for the output record (the harness does this; it waits, then
  asserts). 
- **Submission succeeding ≠ the flow finishing.** A flow can error mid-run and leave a half-filled record
  with *no* ATF error. So the test must **assert the actual output-record fields**, not just that the form
  submitted. Say *"assert the flow's output fields, not just submission"* to be safe.

Choose **server-side E2E** (headless, hands-off) unless you specifically need to validate the rendered
form/portal — in which case it's a UI test and you keep the Client Test Runner tab open.

---

## 7. Rules & gotchas (memorize these five)

1. **Runs are suite-level.** A single test gets wrapped in a one-test suite automatically.
2. **Server-side-only = headless; any UI step needs the runner tab.**
3. **Assert outputs, not submission** — especially for flows/record producers.
4. **3 attempts per root cause**, then it stops and asks you. Read the `atf-reports/` file.
5. **Read results from `sys_atf_test_result`** — there is no `sys_atf_failure_insight` table OOB.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `run_atf_suite` → "URI does not represent any resource" | MCP hardcodes the fake `/api/now/atf/runner` path | Patch MCP to call `/api/sn_cicd/testsuite/run` (ask Claude), or use direct REST |
| `POST /api/sn_cicd/...` → 404 | CI/CD feature not active / no `sn_cicd` rights | Activate CI/CD; use an admin/`sn_cicd` user |
| Tests show **`skipped`** | UI steps with no runner | Open the Client Test Runner tab, re-run |
| "No valid scope found for `<scope>`" on deploy | App scope doesn't exist on the instance | Create the scope / install the app first, then deploy |
| Build drops a step silently | `runServerSideScript` `script` isn't a plain string literal | Remove `.trim()`/concatenation/variables from `script` |
| Impersonated user fails ACLs | Impersonation grants zero roles | Grant roles via a `recordInsert` on `sys_user_has_role` after impersonate |

More detail: see `references/troubleshooting.md` in this plugin.

---

## 9. Learn more (in this plugin)

- **`README.md`** — architecture, file map, the run mechanism.
- **`skills/atf-unified/SKILL.md`** — the full runbook (path selection, the 7 phases, the self-heal contract).
- **`references/sdk-api.md`** — the complete `atf.*` step catalog + build/deploy/runner/limits.
- **`references/troubleshooting.md`** — build/deploy errors + behavioral failure modes.
- **`references/suite-schedule.md`** — suites + nightly scheduling.

**Minimum to remember:** deploy → `/atf-verify <artifact>` → answer the gate if it stops → read the
`atf-reports/` file. That's it.
