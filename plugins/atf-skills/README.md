# atf-skills — Autonomous ATF Testing Harness for ServiceNow

A Claude Code plugin that lets an AI agent **author, deploy, run, and self-heal** ServiceNow Automated
Test Framework (ATF) tests, produce an audit-grade report, and stop for a human only when it can't fix a
failure. Built for any ServiceNow SDK (Fluent / now-sdk) project — not tied to one app.

## What's in here (file map)

```
atf-skills/
├── skills/atf-unified/
│   ├── SKILL.md                     # v3.6.0 — the lean runbook (path selection, 7-phase flow,
│   │                                #   the Phase 6 self-heal + run contract, checklist)
│   └── references/                  # on-demand detail, loaded only when a phase needs it
│       ├── sdk-api.md               #   full atf.* step catalog, build/deploy, runners, limits, OOB
│       ├── troubleshooting.md       #   build/deploy errors + behavioral failure modes
│       └── suite-schedule.md        #   suites + scheduling via SDK Record() or MCP
├── agents/atf-tester.md             # the executor subagent (runs the loop in isolation, returns a verdict)
├── commands/atf-verify.md           # /atf-verify — front door + owns the human gate on BLOCKED
├── hooks/
│   ├── hooks.json                   # PostToolUse hook registration
│   └── atf-postdeploy.sh            # nudges a verification run after `npm run deploy` (lock-guarded)
└── .claude-plugin/plugin.json       # plugin manifest (v1.1.0)
```

## The four layers (and why it's layered, not one thing)

| Layer | File | Role |
|---|---|---|
| **Skill** | `skills/atf-unified/SKILL.md` | The *knowledge* — how to author/build/deploy/run/heal ATF. Passive; the single source of truth. |
| **Subagent** | `agents/atf-tester.md` | The *executor* — follows the skill in its own context, enforces the 3-attempt cap, writes the report, **returns** GREEN/BLOCKED/ERROR. Never prompts the user. |
| **Command** | `commands/atf-verify.md` | The *front door* — `/atf-verify <artifact>` delegates to the subagent and, on BLOCKED, runs the **human gate** (continue / change approach / inspect instance). |
| **Hook** | `hooks/atf-postdeploy.sh` | The *trigger* — after `npm run deploy`, nudges the agent to verify; a lock file prevents the subagent's own deploys from re-triggering it. |

A subagent can't ask the user mid-run, so the **gate lives in the command/main agent**, not the subagent.
The skill stays the only place the rules are written (global `~/.claude/CLAUDE.md` points here — no drift).

## How a run works

```
deploy an artifact ──(hook)──▶ main agent ──▶ /atf-verify ──▶ atf-tester subagent
                                                                   │
   Phase 0 preflight: instance? update set? ATF on? CI/CD trigger? runner (UI only)?
   Phases 1–5: read → register keys → author Test() steps → npm run build → npm run deploy
   Phase 6 RUN + SELF-HEAL (≤3 attempts per root cause, logged to atf-reports/):
        put test(s) in a suite → run_atf_suite(sys_id)
            → POST /api/sn_cicd/testsuite/run         (the real, headless trigger)
            → poll /api/sn_cicd/progress/<id> to 100%
            → read sys_atf_test_result (status + output)
        fail? get the diff, fix the .now.ts, rebuild/redeploy, re-run
   returns ──▶ GREEN  ✅ report + done
              BLOCKED 🚧 main agent asks the user how to proceed
              ERROR   ⛔ environment blocker (e.g. no CI/CD trigger), nothing meaningfully tested
```

Every attempt is appended to `atf-reports/<name>-<date>.md` (expected vs actual, root cause, fix, and for
UI failures a downloaded screenshot) so each run is auditable after the fact.

## The run mechanism (the important bit)

ServiceNow has **no single-test run API** and **no `/api/now/atf/runner/*` endpoint** (that path is
fabricated — it 404s). The only verified headless trigger is the **CI/CD API**, at the **suite** level:

```
POST /api/sn_cicd/testsuite/run?test_suite_sys_id=<id>   → returns a progress link
GET  /api/sn_cicd/progress/<id>                          → poll to percent_complete=100
read sys_atf_test_result (status, output)                → pass/fail + diagnostics
```

- A **server-side-only** suite (all `atf.server.*` steps) runs **fully headless** — no browser.
- A suite with **any UI/browser step** needs a **Client Test Runner** tab open
  (`<instance>/atf_test_runner.do`); the paid Cloud Runner (which would make UI headless) is not on PDIs.
- To run a single test, wrap it in a one-test suite.

This is wired into the MCP server: `servicenow-mcp`'s `run_atf_suite` tool was patched to call
`/api/sn_cicd/testsuite/run` (it previously called the fabricated path). After editing that server you
must rebuild it (`npm run build` in the server dir) and reconnect MCP.

## Using it

- **Manual:** `/atf-verify <artifact-name|path>` (or `--last-deployed`).
- **Automatic:** deploy with `npm run deploy`; the hook nudges a verification.
- **Result:** a verdict in chat + an audit file under the project's `atf-reports/`.

## Related artifacts (outside this plugin)

- **Project test set / reports:** `<project>/src/fluent/tests/*.test.now.ts` and `<project>/atf-reports/*.md`
  — each project keeps its own tests + run reports; this plugin is project-agnostic and ships none.
- **MCP patch:** `~/Desktop/servicenow-mcp/src/tools/atf.ts` (`run_atf_suite` → CI/CD API).
- **Global rule:** `~/.claude/CLAUDE.md` "Self-Healing Loop" delegates to this skill + the `atf-tester` agent.

## Known constraints

- Runs are **suite-level**; **UI-step suites need a browser runner** (not truly headless on a PDI).
- Read diagnostics from `sys_atf_test_result` — there is **no `sys_atf_failure_insight` table** OOB.
- The CI/CD trigger requires the `sn_cicd` feature + `sn_cicd`/admin privileges on the target instance.
