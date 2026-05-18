---
name: atf-sdk
version: 2.0.0
description: Create, deploy, schedule, and self-heal ATF tests for ServiceNow applications built with the now-sdk (Fluent language). SDK authors all server-side tests; MCP creates suites, schedules them, and runs ad-hoc E2E validations.
author: SolvVision
tags: [development, testing, atf, automation, now-sdk, fluent, scoped-app, tdd]
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
    - query_records            # verify tests landed; check for duplicates before creating
    - run_atf_test             # execute tests (requires ATF_ENABLED=true in MCP config)
    - get_atf_failure_insight  # root-cause failed tests
    - get_current_instance     # confirm target instance
    - create_record            # create ATF suites (sys_atf_test_suite + sys_atf_test_suite_test)
    - create_scheduled_job     # schedule suite runs (sysauto_script, daily/weekly)
    - order_catalog_item       # ad-hoc E2E: submit catalog item and observe downstream records
complexity: intermediate
estimated_time: 15-30 minutes
---

# ATF Tests for ServiceNow SDK (Fluent) Projects

## Overview

This skill creates ATF tests for ServiceNow scoped applications built with the `now-sdk` and Fluent language. Tests are authored as TypeScript files using the `Test()` API from `@servicenow/sdk/core`, compiled into ServiceNow XML by the SDK build pipeline, and deployed via `npm run deploy`.

**This is not the same as creating ATF tests via MCP or the ServiceNow UI.** The SDK generates properly scoped `sys_atf_test` and `sys_atf_step` records with `sys_variable_value` entries — the correct format for scoped app delivery.

**When to use this skill:**
- You have a `now-sdk` project with a `src/fluent/` directory
- You are implementing or have just deployed a new artifact (Script Include, Business Rule, Catalog Item, Flow, Table, ACL)
- You need ATF tests that travel with the app in version control and deploy as part of the app package
- You need to test OOB scope behavior (HRSD, CSM, ITSM, etc.) — **SDK server-side steps can target any table regardless of scope**. The test record lives in your custom app scope, but `recordInsert`, `recordValidation`, `recordDelete`, and `runServerSideScript` can operate on `sn_hr_core_case`, `sn_csm_case`, or any other table. This is the correct approach for server-side functional testing of OOB modules without Now Assist for Creator.

**When NOT to use this skill:**
- Your project does not use `now-sdk` → use the MCP path in `ATF_UNIFIED_SKILL.md` instead
- You need UI/browser-based tests that drive the Employee Center portal or any platform form (open item, fill fields, click Submit) → **this cannot be done programmatically by any tool**. The `sys_atf_step.inputs` field for catalog/browser step types is a compressed XML blob that cannot be populated via `create_record`, background scripts, or any MCP tool. Portal-path ATF steps require the ServiceNow ATF UI — or Now Assist for Creator if that plugin is installed.

## Prerequisites

- **Project:** `now-sdk` project with `src/fluent/` directory and `package.json` containing `@servicenow/sdk`
- **Keys file:** `src/fluent/generated/keys.ts` must exist — all test and step IDs are registered here
- **Artifact deployed:** The artifact being tested must already exist on the target instance
- **Instance access:** Confirm the target instance in `now.config.json` or by asking the user

## Artifact-Type → Test Pattern

| Artifact | What to assert | Primary step types |
|---|---|---|
| Script Include | Each public method: return value, edge cases (empty input, missing optional fields) | `server.runServerSideScript` (Jasmine) |
| Business Rule | Insert/update the trigger record; assert the expected side-effect occurred | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Catalog Item | (1) Server-side: create test user → impersonate → submit via `GlideCatalogCart` → poll for downstream record → assert fields including `submitted_by` → revert impersonation → delete standup entry + RITM + sc_request + test user. (2) ESC portal UI test (open Employee Center → navigate to item → fill variables → submit) requires catalog `step_config` types not available in SDK — use MCP or ServiceNow UI for those steps. | `server.recordInsert` (sys_user), `server.impersonate`, `server.runServerSideScript`, `server.recordDelete` |
| Flow / Subflow | Insert the record that triggers the flow; assert the output record | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Table / Fields | Assert required fields exist with the correct type and mandatory flag | `server.runServerSideScript` |
| ACL | Impersonate a user with and without the required role; assert allowed / denied | `server.impersonate`, `server.recordInsert`, `server.recordValidation` |
| OOB Module (HRSD, CSM, ITSM) | Server-side only: insert a case/record in the OOB table, trigger the workflow, assert state and field values. Test record lives in custom scope; steps target OOB tables directly. Cross-scope Script Include calls may require explicit cross-scope access grants in ServiceNow. | `server.recordInsert` (OOB table), `server.runServerSideScript`, `server.recordValidation`, `server.recordDelete` |

---

## Procedure

### Phase 1: Read Before Writing

Never write a test before understanding the code.

**Step 1.1 — Read the artifact source**

```bash
# Fluent definition
Read src/fluent/<type>/<ArtifactName>.now.ts

# Server-side implementation
Read src/server/<type>/<ArtifactName>.server.js
```

**Step 1.2 — Check for existing tests**

```bash
find src/fluent/tests -name "*.test.now.ts" | xargs grep -l "<ArtifactName>" 2>/dev/null
```

If a test already exists for this artifact, do not create a duplicate. Update the existing one if coverage is missing.

**Step 1.3 — Confirm the target instance**

Check `now.config.json` for the instance URL, or call `get_current_instance` if MCP is available. Never assume.

---

### Phase 2: Register IDs in keys.ts

Every `sys_atf_test` and every `sys_atf_step` requires a `Now.ID` entry in `src/fluent/generated/keys.ts` under the `explicit` block. Add all entries before writing the test file.

```typescript
// In src/fluent/generated/keys.ts — add inside the explicit block:
'test-my-artifact': {
    table: 'sys_atf_test'
    id: '<32-char-hex>'
}
'test-my-artifact-step-insert': {
    table: 'sys_atf_step'
    id: '<32-char-hex>'
}
'test-my-artifact-step-validate': {
    table: 'sys_atf_step'
    id: '<32-char-hex>'
}
'test-my-artifact-step-delete': {
    table: 'sys_atf_step'
    id: '<32-char-hex>'
}
```

IDs must be unique 32-character hex strings. Generate them as random sequences — they only need to be unique within the file.

---

### Phase 3: Write the Test File

**Location:** `src/fluent/tests/<ArtifactName>.test.now.ts`
**Test name convention:** `Test - <ArtifactName>`

**Step 3.1 — Test skeleton**

```typescript
import { Test } from '@servicenow/sdk/core'

Test(
    {
        $id: Now.ID['test-my-artifact'],
        name: 'Test - MyArtifact',
        description: '<one sentence: what scenario this test validates>',
        active: true,
        failOnServerError: true,
    },
    (atf) => {
        // steps go here
    }
)
```

**Step 3.2 — server.runServerSideScript**

Use for Script Include unit tests and schema validation. Executes Jasmine on the server.

```typescript
atf.server.runServerSideScript({
    $id: Now.ID['test-my-artifact-step-script'],
    description: 'Verify MyClass.myMethod returns expected output',
    script: `describe('MyClass.myMethod', function() {
    it('returns a non-empty string', function() {
        var obj = new x_<scope_prefix>.MyClass();
        var result = obj.myMethod('valid input');
        expect(typeof result).toBe('string');
        expect(result.length).toBeGreaterThan(0);
    });
    it('handles empty input without throwing', function() {
        var obj = new x_<scope_prefix>.MyClass();
        var result = obj.myMethod('');
        expect(result).toBeDefined();
    });
});`,
})
```

> **Critical:** The `script` value must be a plain string literal. No `.trim()`, no string concatenation, no template expressions, no variables. The SDK build plugin performs static analysis and will silently drop the step if the value is not a literal — the build will succeed but the step will be missing from the output XML.

Available Jasmine matchers: `toBe`, `toEqual`, `toContain`, `toBeDefined`, `toBeGreaterThan`, `toBeLessThanOrEqualTo`, `not.toContain`, `not.toBeDefined`.

Reference scoped Script Includes as `x_<scope_prefix>.<ClassName>()`.

**Step 3.3 — server.recordInsert**

Use to create test data the test needs. Captures the inserted record's sys_id for use in subsequent steps.

```typescript
const inserted = atf.server.recordInsert({
    $id: Now.ID['test-my-artifact-step-insert'],
    description: 'Create test record with known field values',
    table: 'x_scope_my_table',
    fieldValues: {
        field_one: 'ATF test value',
        field_two: 'another value',
    },
    enforceSecurity: false,
})
```

**Step 3.4 — server.recordValidation**

Use to assert field values on a record after an action has occurred.

```typescript
atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate'],
    description: 'Assert the record contains the expected values',
    table: 'x_scope_my_table',
    recordId: inserted.record_id,
    fieldValues: 'field_oneCONTAINSATF test value^field_twoSTARTSWITHanother',
    enforceSecurity: false,
})
```

`fieldValues` is a ServiceNow encoded query string. Operators are embedded in the field name:

| Operator | Syntax | Example |
|---|---|---|
| Equals | `fieldEQvalue` | `stateEQ1` |
| Contains | `fieldCONTAINSvalue` | `nameCONTAINStest` |
| Starts with | `fieldSTARTSWITHvalue` | `numberSTARTSWITHINC` |
| Greater than | `fieldGT value` | `priorityGT2` |
| Is not empty | `fieldISNOTEMPTY` | `assigned_toISNOTEMPTY` |

**Step 3.5 — server.recordDelete**

Always clean up test data. Place this as the last step.

```typescript
atf.server.recordDelete({
    $id: Now.ID['test-my-artifact-step-delete'],
    description: 'Remove test record to leave no residual data',
    table: 'x_scope_my_table',
    recordId: inserted.record_id,
    enforceSecurity: false,
})
```

**Step 3.6 — server.impersonate**

Use for ACL tests to switch the executing user mid-test, and for catalog item tests to submit as a real user.

```typescript
atf.server.impersonate({
    $id: Now.ID['test-my-artifact-step-impersonate'],
    description: 'Switch to a user without the required role to test access restriction',
    user: '<sys_id>',
})
```

**Critical:** `user` only accepts a **sys_id** — never a username string like `'admin'`. Passing a username causes a runtime failure: "User with sys_id 'admin' does not exist". To impersonate a dynamically created user, pass `insertedUser.record_id`. To revert to admin, look up the admin sys_id first (`sys_user` where `user_name=admin`) and hardcode it — do not pass the string `'admin'`.

---

### Phase 4: Build

```bash
npm run build
```

**Expected output:** `Build completed successfully` with no warnings.

**If you see:** `Plugin "TestPlugin" failed to transform "CallExpressionShape" shape into record`
→ A `runServerSideScript` step has a non-literal `script` value. Remove `.trim()`, concatenation, or any variable reference from the `script` field.

**Verify the XML was generated:**

```bash
find dist/app -name "sys_atf_test_*.xml" -o -name "sys_atf_step_*.xml"
```

There must be one `sys_atf_test_*.xml` per test and one `sys_atf_step_*.xml` per step. A missing step file means the build silently dropped it — fix before deploying.

---

### Phase 5: Deploy

```bash
npm run deploy
```

If this fails with `Could not determine app installation status`:

```bash
npm run deploy -- --reinstall
```

The `--reinstall` flag uninstalls and reinstalls the full app. It is the reliable deploy path when the standard install poll times out.

---

### Phase 6: Verify (MCP optional)

**If MCP is available — confirm tests landed:**

```
query_records(
    table: 'sys_atf_test',
    query: 'sys_scope.scope=<your_app_scope>',
    fields: 'sys_id,name,active'
)
```

Every test created must appear. If any are missing: rebuild and redeploy.

**If MCP is not available:** navigate to the instance and go to `Automated Test Framework > Tests`, filter by application scope.

---

### Phase 7: Run Tests and Self-Heal

**If MCP has ATF execution enabled:**

```
run_atf_test(sys_id: '<test_sys_id>')
```

**If MCP returns `ATF_NOT_ENABLED`:** run the test from the ServiceNow UI:

```
https://<instance>.service-now.com/sys_atf_test.do?sys_id=<test_sys_id>
```

Navigate to **Automated Test Framework > Tests**, open the test, and click **Run Test**.

**Self-healing loop (repeat until green):**

1. Get the failure detail:
   ```
   get_atf_failure_insight(result_sys_id: '<result_sys_id>')
   ```
   Or read the step result message in the UI.

2. Identify the exact failure: which assertion, actual vs expected value.

3. Fix the source `.now.ts` file.

4. Rebuild → redeploy → re-run.

5. Repeat.

**Stop after 3 iterations on the same root cause.** Report the exact failure message and every fix attempted, then ask the user how to proceed.

---

---

### Phase 8: Create a Suite and Schedule It (MCP)

The SDK `Test()` API creates individual tests only — suites and scheduled jobs require MCP write tools. Both `create_record` (for `sys_atf_test_suite` and `sys_atf_test_suite_test`) and `create_scheduled_job` work reliably when `WRITE_ENABLED=true` is set on the MCP server.

**Step 8.1 — Check for an existing suite**

```
query_records(
    table: 'sys_atf_test_suite',
    query: 'sys_scope.scope=<your_app_scope>',
    fields: 'sys_id,name,active'
)
```

**Step 8.2 — Create the suite**

```
create_record(
    table: 'sys_atf_test_suite',
    fields: {
        name: 'Suite - <ArtifactName>',
        description: '<one sentence: what this suite covers>',
        active: 'true',
        sys_scope: '<scope_sys_id>'
    }
)
```

Note the returned `sys_id` — this is the suite sys_id.

**Step 8.3 — Add tests to the suite**

For each test (repeat per test):

```
create_record(
    table: 'sys_atf_test_suite_test',
    fields: {
        test_suite: '<suite_sys_id>',
        test: '<test_sys_id>',
        order: '100'   # increment by 100 per test
    }
)
```

**Step 8.4 — Schedule the suite**

```
create_scheduled_job(
    name: 'Scheduled - Suite <ArtifactName> (Nightly)',
    script: "var suiteGr = new GlideRecord('sys_atf_test_suite');\nsuiteGr.get('<suite_sys_id>');\nvar runner = new SncATFTestSuiteRunner(suiteGr);\nrunner.run();",
    run_type: 'daily',
    run_time: '06:00:00',
    active: true
)
```

---

### Phase 9: Ad-Hoc MCP E2E Validation (Catalog Items)

When you need to verify the full catalog item → flow → output record chain without building an ATF test, `order_catalog_item` provides an MCP-driven E2E path. This runs outside the ATF framework — it creates a real request on the instance that must be cleaned up.

**Pattern:**

1. Submit the catalog item:
   ```
   order_catalog_item(
       sys_id: '<catalog_item_sys_id>',
       variables: {
           worked_on: 'MCP E2E test value',
           next_up: 'MCP E2E next value',
           blockers: ''
       }
   )
   ```

2. Poll for the downstream output record:
   ```
   query_records(
       table: '<output_table>',
       query: 'worked_onCONTAINSMCP E2E test value',
       fields: 'sys_id,worked_on,next_up,submitted_by,sys_created_on',
       orderBy: '-sys_created_on',
       limit: 1
   )
   ```

3. Assert the expected fields are populated.

4. Clean up: delete the output record, RITM, and sc_request.

**Limitation:** This is a Claude-driven test, not an on-instance ATF record. It cannot be scheduled. Use the SDK test for the schedulable equivalent.

---

## Hard Limits

These are things that **cannot** be done programmatically regardless of which MCP server or tools are used:

| Limitation | Root cause | Workaround |
|---|---|---|
| Create portal/browser ATF steps (catalog item open, ESC navigation, form fill) | `sys_atf_step.inputs` is a compressed XML blob; `create_record` inserts a structurally empty step that the ATF runner cannot interpret | Create in the ServiceNow ATF UI manually |
| Execute background scripts | Requires the `/api/now/v1/scripted_rest_services/bg_script` endpoint to be enabled on the instance; off by default on PDIs | Enable via System Properties or use nowaikit with `SCRIPTING_ENABLED=true` — instance may still block the endpoint |
| Run ATF tests via MCP | Requires `ATF_ENABLED=true` in MCP server config AND the instance to have ATF enabled | Run from the ServiceNow UI: `https://<instance>.service-now.com/sys_atf_test.do?sys_id=<test_sys_id>` |

---

## Complete Examples

### Example 1: Script Include Unit Test

```typescript
import { Test } from '@servicenow/sdk/core'

Test(
    {
        $id: Now.ID['test-standup-utils'],
        name: 'Test - StandupUtils',
        description: 'Unit tests for StandupUtils: formatEntry and getRecentEntries',
        active: true,
        failOnServerError: true,
    },
    (atf) => {
        atf.server.runServerSideScript({
            $id: Now.ID['test-standup-utils-step-format'],
            description: 'Verify formatEntry returns a string with worked_on and next_up values',
            script: `describe('StandupUtils.formatEntry', function() {
    it('returns a non-empty string', function() {
        var utils = new x_1970577_countess.StandupUtils();
        var gr = new GlideRecord('x_1970577_countess_standup_entry');
        gr.initialize();
        gr.setValue('worked_on', 'Fixed auth bug');
        gr.setValue('next_up', 'Deploy to staging');
        gr.setValue('blockers', '');
        gr.setValue('date', gs.nowDate());
        var result = utils.formatEntry(gr);
        expect(typeof result).toBe('string');
        expect(result.length).toBeGreaterThan(0);
    });
    it('omits Blockers line when blockers is empty', function() {
        var utils = new x_1970577_countess.StandupUtils();
        var gr = new GlideRecord('x_1970577_countess_standup_entry');
        gr.initialize();
        gr.setValue('worked_on', 'Work');
        gr.setValue('next_up', 'Next');
        gr.setValue('blockers', '');
        gr.setValue('date', gs.nowDate());
        var result = utils.formatEntry(gr);
        expect(result).not.toContain('Blockers:');
    });
});`,
        })
    }
)
```

### Example 2: Table Insert / Validate / Delete

```typescript
import { Test } from '@servicenow/sdk/core'

Test(
    {
        $id: Now.ID['test-standup-entry'],
        name: 'Test - Standup Entry',
        description: 'Verify standup entry records can be inserted, validated, and deleted',
        active: true,
        failOnServerError: true,
    },
    (atf) => {
        const inserted = atf.server.recordInsert({
            $id: Now.ID['test-standup-entry-step-insert'],
            description: 'Insert a standup entry with all required fields',
            table: 'x_1970577_countess_standup_entry',
            fieldValues: {
                worked_on: 'ATF test: insert step',
                next_up: 'ATF test: validate step',
                blockers: '',
                date: '2026-05-08',
            },
            enforceSecurity: false,
        })

        atf.server.recordValidation({
            $id: Now.ID['test-standup-entry-step-validate'],
            description: 'Confirm worked_on and next_up contain the expected values',
            table: 'x_1970577_countess_standup_entry',
            recordId: inserted.record_id,
            fieldValues: 'worked_onCONTAINSATF test: insert step^next_upCONTAINSATF test: validate step',
            enforceSecurity: false,
        })

        atf.server.recordDelete({
            $id: Now.ID['test-standup-entry-step-delete'],
            description: 'Remove the test record',
            table: 'x_1970577_countess_standup_entry',
            recordId: inserted.record_id,
            enforceSecurity: false,
        })
    }
)
```

---

## Best Practices

### Test design
- **One scenario per test** — keep each test focused on a single behavior
- **Edge cases required** — every test must include at least one non-happy-path assertion (empty input, missing optional field, boundary value)
- **No dependency on existing data** — create everything you need with `recordInsert`, clean up with `recordDelete`
- **Readable descriptions** — every step needs a `description` that explains what it asserts, not just what it does

### Keys.ts hygiene
- Add all IDs before writing the test file
- Use descriptive key names: `test-<artifact>`, `test-<artifact>-step-<action>`
- Never reuse an existing ID for a new record

### Build hygiene
- Always verify the `dist/app/` XML before deploying — a missing step file means the build dropped it silently
- Fix TestPlugin warnings immediately — they indicate steps that will be absent from the instance

### Data hygiene
- Prefix test data values with `ATF test:` so they are identifiable if cleanup fails
- Always end every test with `recordDelete` for every record inserted

---

## Troubleshooting

### TestPlugin warning during build

**Symptom:** `Plugin "TestPlugin" failed to transform "CallExpressionShape" shape into record`

**Cause:** The `script` field of a `runServerSideScript` step is not a static string literal.

**Fix:** Remove `.trim()`, string concatenation, template expression calls, or any variable from the `script` value. It must be a plain backtick or quoted string with no runtime operations.

### Step missing from dist/app after build

**Symptom:** Build succeeds but `find dist/app -name "sys_atf_step_*.xml"` returns fewer files than expected.

**Cause:** The affected step's build transformation failed silently (usually the same cause as above).

**Fix:** Check for the TestPlugin warning, fix the `script` literal, rebuild.

### Deploy fails with "Could not determine app installation status"

**Symptom:** `npm run deploy` exits with the error after ~30 seconds.

**Fix:**
```bash
npm run deploy -- --reinstall
```

### Test not found on instance after deploy

**Symptom:** MCP `query_records` or the ATF UI does not show the test.

**Cause:** Deploy may have used stale build output, or the reinstall did not pick up the latest build.

**Fix:** Run `npm run build` followed by `npm run deploy -- --reinstall`.

### ATF_NOT_ENABLED from MCP

**Symptom:** `run_atf_test` returns `ATF test execution is disabled. Set ATF_ENABLED=true`.

**Fix:** Run the test from the ServiceNow UI directly. The MCP server config does not have `ATF_ENABLED=true` — this is an MCP configuration issue, not a test issue.

### Portal/browser ATF step created via create_record has no configuration

**Symptom:** You created an ATF step with a catalog/browser step_config via MCP `create_record`, but when you open it in the ServiceNow UI the step inputs are empty and the ATF runner skips or errors on it.

**Cause:** The `sys_atf_step.inputs` field is a compressed XML blob. The REST API receives the value but cannot reconstruct the proper compressed structure. The step record exists but is functionally empty.

**Fix:** This cannot be repaired programmatically. Open the test in the ServiceNow ATF UI (`Automated Test Framework > Tests`), find the step, delete it, and recreate it using the UI's step config form — which populates the compressed inputs correctly.

### nowaikit MCP server returning 502 on all calls

**Symptom:** All `mcp__nowaikit__*` tool calls return `HTTP 502: Bad Gateway`.

**Cause:** The nowaikit server is pointed at the wrong ServiceNow instance (wrong `SERVICENOW_INSTANCE_URL` in the MCP config), or the instance is hibernated.

**Fix:**
```bash
claude mcp get nowaikit   # check SERVICENOW_INSTANCE_URL
claude mcp remove nowaikit -s local
claude mcp add nowaikit -s local \
  -e SERVICENOW_INSTANCE_URL=https://<correct-instance>.service-now.com \
  -e SERVICENOW_AUTH_METHOD=basic \
  -e SERVICENOW_BASIC_USERNAME=admin \
  -e "SERVICENOW_BASIC_PASSWORD=<password>" \
  -e WRITE_ENABLED=true \
  -e SCRIPTING_ENABLED=true \
  -e ATF_ENABLED=true \
  -- node /Users/<you>/nowaikit/dist/server.js
```
Then restart the Claude Code session for the new config to take effect.

---

## Checklist

Before reporting the task complete, every item must be true:

- [ ] Artifact source read and understood before writing assertions
- [ ] No existing test duplicated
- [ ] All test and step IDs registered in `keys.ts`
- [ ] `npm run build` passes — no TestPlugin warnings
- [ ] `dist/app/` contains one `sys_atf_test_*.xml` per test and one `sys_atf_step_*.xml` per step
- [ ] Deploy succeeded
- [ ] Tests confirmed on instance (MCP query or UI check)
- [ ] Tests passed, or exact failure message reported with all fix attempts documented

---

## Related Skills

- `ATF_SKILL.md` — MCP-based ATF creation for non-SDK ServiceNow projects
- `admin/update-set-management` — version control for tests outside the SDK
- `admin/deployment-workflow` — promote tests between instances

## References

- [ServiceNow SDK — Test()](https://docs.servicenow.com/csh?topicname=atf-test-now-ts.html&version=latest)
- [ATF Documentation](https://docs.servicenow.com/bundle/utah-application-development/page/administer/auto-test-framework/concept/automated-test-framework.html)
- [now-sdk CLI reference](https://docs.servicenow.com/bundle/utah-application-development/page/build/servicenow-sdk/concept/sdk-overview.html)
