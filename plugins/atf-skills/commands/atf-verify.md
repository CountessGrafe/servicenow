---
description: Build, run, and self-heal ATF coverage for an artifact via the atf-tester agent, then own the human gate on a BLOCKED result
argument-hint: "[<artifact-name|path> | --last-deployed]"
allowed-tools: Task, AskUserQuestion, Read, Bash(find:*), Bash(ls:*), mcp__servicenow-mcp__get_current_instance, mcp__servicenow-mcp__get_current_update_set, mcp__nowaikit__get_current_instance, mcp__nowaikit__get_current_update_set
---

Run a complete, self-healing ATF verification for a ServiceNow artifact and stay in control of the
human-in-the-loop decision. You are the **caller/coordinator**; the `atf-tester` subagent is the worker.

## Target

Resolve the target from `$ARGUMENTS`:
- A name or path (e.g. `StandupUtils`, `src/fluent/catalog-items/SubmitDailyStandup.now.ts`) → that artifact.
- `--last-deployed` or empty → the artifact(s) changed in this session (infer from recently modified
  `src/fluent/**` files). State the inferred target before proceeding.

## Steps

1. **Confirm the environment (read-only).** `get_current_instance` and `get_current_update_set`. Show the
   user which instance + update set will be used and that the update set scope matches the artifact. If the
   instance is ambiguous or the scope is wrong, say so and stop — do not test against the wrong target.

2. **Delegate to the `atf-tester` agent.** Use the Task tool with `subagent_type: atf-tester`, passing the
   resolved artifact (or "verify the artifacts changed this session") and whether a suite + schedule is
   wanted. The agent runs preflight → author → build → deploy → run → self-heal (≤3 attempts/root cause) →
   writes `atf-reports/<name>-<date>.md` + downloads screenshots → returns an `ATF VERDICT` block. Wait for
   it; do not run the loop yourself.

3. **Act on the verdict:**

   - **GREEN** → Report success. Link the report file and name the passing test/suite sys_ids. Done.

   - **ERROR** (environment blocker — ATF disabled, no browser runner, wrong instance, deploy can't
     succeed) → Surface the blocker plainly and the fix (open `<instance>/atf_test_runner.do` in a tab,
     enable ATF in MCP config, switch instance, etc.). Offer to re-run once the user resolves it. Nothing
     was meaningfully tested — do not present this as a test failure.

   - **BLOCKED** (3 attempts exhausted on one root cause) → **This is the human gate.** Summarize the
     `needs_from_user` line and the fixes already tried, then call **AskUserQuestion** with exactly three
     options:
       - **Continue self-healing** — re-delegate to `atf-tester` with "continue; prior report at
         `<report path>`", allowing a fresh set of attempts (note in the report that the user authorized
         another pass).
       - **Change approach** — ask the user for the new direction (or propose one: switch UI surface,
         change the assertion strategy, server-side instead of UI), then re-delegate with that strategy.
       - **I'll inspect the instance** — stop. Leave the report and the BLOCKED block in place; hand
         control back to the user. Do not mark the task complete.

4. **Never report complete while a BLOCKED block stands** unresolved. Always end by pointing the user at
   the `atf-reports/` audit file so the run is reviewable.
