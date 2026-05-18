---
name: atf-unified
version: 1.0.0
description: Unified ATF skill for ServiceNow. Auto-detects whether to use the SDK path (now-sdk scoped app) or the MCP path (global/OOB scope). Covers test authoring, suite creation, scheduling, and all known hard limits.
author: SolvVision
tags: [development, testing, atf, automation, now-sdk, fluent, mcp, scoped-app, global, oob, hrsd, csm]
platforms: [claude-code]
tools:
  sdk:
    - npm run build
    - npm run deploy -- --reinstall
  native:
    - Bash
    - Read
    - Edit
    - Write
  mcp:
    - query_records             # check existing tests, verify deployment
    - create_record             # create suites (sys_atf_test_suite, sys_atf_test_suite_test)
    - create_scheduled_job      # schedule suite runs
    - order_catalog_item        # ad-hoc E2E catalog item validation
    - run_atf_test              # execute tests (requires ATF_ENABLED=true)
    - get_atf_failure_insight   # root-cause failures
    - get_current_instance      # confirm target instance
complexity: intermediate
estimated_time: 15–45 minutes
---

# ATF Unified Skill — ServiceNow

## Auto-Detection: Which Path to Use

Run these checks in order before writing a single line of test code.

### Check 1 — Does a now-sdk project exist?

```bash
cat package.json | grep "@servicenow/sdk"
ls src/fluent/
```

- **Both exist** → **SDK path** (see [SDK Path](#sdk-path))
- **Neither exists** → **MCP path** (see [MCP Path](#mcp-path))

### Check 2 — What scope is the artifact in?

```
query_records(table: 'sys_scope', query: 'scope=<artifact_scope>', fields: 'sys_id,name,scope')
```

| Scope type | Example | Recommended path |
|---|---|---|
| Custom app in now-sdk project | `x_<scope_prefix>` | SDK path |
| Global | `global` | MCP path (suite/schedule only) + manual UI for steps |
| OOB module | `sn_hr_core`, `sn_csm`, `sn_incident` | SDK path (server-side) for functional testing; manual UI for browser steps |

### Check 3 — Do you need browser/portal UI steps?

Portal UI steps (open ESC portal, fill form fields, click Submit) **cannot be created programmatically** by any tool. See [Hard Limits](#hard-limits).

- **Yes, you need browser steps** → ServiceNow ATF UI (manual) or Now Assist for Creator (if plugin installed)
- **No, server-side is sufficient** → proceed with SDK or MCP path

---

## SDK Path

**Use when:** a `now-sdk` project exists. Covers custom app artifacts AND server-side testing of OOB module tables (HRSD, CSM, ITSM, etc.).

### Artifact-Type → Test Pattern

| Artifact | Test pattern | Step types |
|---|---|---|
| Script Include | Call each public method; assert return values and edge cases | `server.runServerSideScript` (Jasmine) |
| Business Rule | Insert/update the trigger record; assert the side-effect | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Catalog Item | Create test user → impersonate → submit via `GlideCatalogCart` → poll for output record → assert fields including `submitted_by` → revert impersonation → cleanup RITM + sc_request + test user | `server.recordInsert` (sys_user), `server.impersonate`, `server.runServerSideScript`, `server.recordDelete` |
| Flow / Subflow | Insert trigger record; poll for output record; assert fields | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Table / Fields | Assert required fields, types, and mandatory flags via `GlideTableDescriptor` | `server.runServerSideScript` |
| ACL | Impersonate user with/without role; assert allowed/denied | `server.impersonate`, `server.recordInsert`, `server.recordValidation` |
| OOB module (HRSD, CSM, ITSM) | Insert a case/record in the OOB table from your custom scope; trigger the workflow; assert state and output fields. Note: cross-scope Script Include calls require explicit access grants. | `server.recordInsert` (OOB table), `server.runServerSideScript`, `server.recordValidation`, `server.recordDelete` |

### Step 1 — Read before writing

```bash
Read src/fluent/<type>/<ArtifactName>.now.ts
Read src/server/<type>/<ArtifactName>.server.js
find src/fluent/tests -name "*.test.now.ts" | xargs grep -l "<ArtifactName>" 2>/dev/null
```

Never write a test before reading the artifact source. Never duplicate an existing test.

### Step 2 — Register IDs in keys.ts

Every test and step needs an entry in `src/fluent/generated/keys.ts` under the `explicit` block:

```typescript
'test-my-artifact': {
    table: 'sys_atf_test'
    id: '<32-char-hex>'
}
'test-my-artifact-step-insert': {
    table: 'sys_atf_step'
    id: '<32-char-hex>'
}
```

### Step 3 — Write the test file

**Location:** `src/fluent/tests/<ArtifactName>.test.now.ts`

```typescript
import { Test } from '@servicenow/sdk/core'

Test(
    {
        $id: Now.ID['test-my-artifact'],
        name: 'Test - MyArtifact',
        description: '<one sentence describing what this test validates>',
        active: true,
        failOnServerError: true,
    },
    (atf) => {
        // steps
    }
)
```

**Key rules:**
- `runServerSideScript` — `script` must be a plain string literal (no `.trim()`, no concatenation, no variables). The SDK build plugin silently drops the step if the value is not static.
- `server.impersonate` — `user` field only accepts a sys_id, never a username string. Passing `'admin'` causes "User with sys_id 'admin' does not exist" at runtime.
- Always end with `recordDelete` for every record inserted. Never leave test data on the instance.
- Include at least one edge case per test (empty input, missing optional field, boundary value).

**Catalog Item pattern (GlideCatalogCart — the only server-side E2E approach):**

```typescript
// Step 1: Create isolated test user
const testUser = atf.server.recordInsert({
    $id: Now.ID['test-my-artifact-step-create-user'],
    table: 'sys_user',
    fieldValues: { user_name: 'atf.test.user', first_name: 'ATF', last_name: 'Test',
                   email: 'atf@test.local', active: 'true' },
    enforceSecurity: false,
})

// Step 2: Impersonate the test user
atf.server.impersonate({
    $id: Now.ID['test-my-artifact-step-impersonate'],
    user: testUser.record_id,   // sys_id, not username
})

// Step 3: Submit via GlideCatalogCart + poll for output record
atf.server.runServerSideScript({
    $id: Now.ID['test-my-artifact-step-submit'],
    script: `describe('Catalog Item E2E', function() {
    it('submits and flow creates output record', function() {
        var cart = new GlideCatalogCart();
        var guid = cart.addItemToCart('<catalog_item_sys_id>');
        cart.setVariable(guid, 'field1', 'test value');
        var requestSysId = cart.placeOrder();
        expect(requestSysId).toBeTruthy();
        var found = '';
        for (var i = 0; i < 15; i++) {
            gs.sleep(2000);
            var gr = new GlideRecord('<output_table>');
            gr.addQuery('field1', 'CONTAINS', 'test value');
            gr.setLimit(1); gr.query();
            if (gr.next()) { found = gr.getUniqueValue(); break; }
        }
        expect(found).toBeTruthy();
    });
});`,
})

// Step 4: Revert impersonation to admin (use sys_id, not 'admin')
atf.server.impersonate({
    $id: Now.ID['test-my-artifact-step-revert'],
    user: '<admin_sys_id>',   // query sys_user where user_name=admin to get this
})

// Step 5: Cleanup (delete output record, RITM, sc_request, test user)
atf.server.runServerSideScript({ $id: Now.ID['test-my-artifact-step-cleanup'], script: `...` })
atf.server.recordDelete({ $id: Now.ID['test-my-artifact-step-delete-user'],
    table: 'sys_user', recordId: testUser.record_id, enforceSecurity: false })
```

### Step 4 — Build

```bash
npm run build
```

Expected: `Build completed successfully`, no `Plugin "TestPlugin" failed to transform` warnings.

Verify XML:
```bash
find dist/app -name "sys_atf_test_*.xml" -o -name "sys_atf_step_*.xml"
```

One file per test, one per step. A missing step = build dropped it silently (fix the static string rule).

### Step 5 — Deploy

```bash
npm run deploy -- --reinstall
```

`--reinstall` is the reliable path on PDIs. Standard deploy times out.

### Step 6 — Verify

```
query_records(table: 'sys_atf_test', query: 'sys_scope.scope=<app_scope>',
              fields: 'sys_id,name,active')
```

Every test must appear. Missing = rebuild and redeploy.

### Step 7 — Run and self-heal

```
run_atf_test(sys_id: '<test_sys_id>')
```

If `ATF_NOT_ENABLED`: run from `https://<instance>.service-now.com/sys_atf_test.do?sys_id=<test_sys_id>`

If test fails:
1. `get_atf_failure_insight(result_sys_id: '<result_sys_id>')` — get exact failure message
2. Fix the source `.now.ts` file
3. Rebuild → redeploy → re-run
4. Stop after 3 iterations on the same root cause — report blocker and ask user

---

## MCP Path

**Use when:** no `now-sdk` project exists, or artifact is in global/OOB scope and only suite/scheduling is needed (steps were created via the ServiceNow UI).

### What MCP can do

| Action | MCP tool | Notes |
|---|---|---|
| Check existing tests | `query_records` on `sys_atf_test` | Always check before creating |
| Create ATF suite | `create_record` on `sys_atf_test_suite` | Works for any scope |
| Add test to suite | `create_record` on `sys_atf_test_suite_test` | Link suite + test + order |
| Schedule suite | `create_scheduled_job` | Daily/weekly/monthly |
| Ad-hoc E2E (catalog items) | `order_catalog_item` + `query_records` | Not schedulable — Claude-driven only |
| Run test | `run_atf_test` | Requires `ATF_ENABLED=true` in MCP config |
| Root-cause failure | `get_atf_failure_insight` | Pass the result sys_id |

### Create a suite

```
// 1. Check for existing suite
query_records(table: 'sys_atf_test_suite',
              query: 'nameCONTAINS<ArtifactName>^sys_scope.scope=<scope>',
              fields: 'sys_id,name')

// 2. Create suite
create_record(table: 'sys_atf_test_suite', fields: {
    name: 'Suite - <ArtifactName>',
    description: '<what this covers>',
    active: 'true',
    sys_scope: '<scope_sys_id>'
})

// 3. Add each test (repeat per test)
create_record(table: 'sys_atf_test_suite_test', fields: {
    test_suite: '<suite_sys_id>',
    test: '<test_sys_id>',
    order: '100'   // increment by 100 per test
})
```

### Schedule the suite

```
create_scheduled_job(
    name: 'Scheduled - Suite <ArtifactName> (Nightly)',
    script: "var gr = new GlideRecord('sys_atf_test_suite');\ngr.get('<suite_sys_id>');\nnew SncATFTestSuiteRunner(gr).run();",
    run_type: 'daily',
    run_time: '06:00:00',
    active: true
)
```

### What MCP cannot do

**Creating individual ATF steps via MCP is not possible for any step type.** The `sys_atf_step.inputs` field is a compressed XML blob. `create_record` inserts a structurally empty step that the ATF runner cannot interpret. This applies to every step config — server-side scripts, record inserts, form steps, catalog steps.

**The only exception** is steps created by the SDK build pipeline, which uses `sys_variable_value` records instead of the `inputs` field.

---

## Hard Limits (verified, 2026-05-11)

These limitations were confirmed through direct testing. No workaround exists within Claude Code.

| Limitation | Root cause | Workaround |
|---|---|---|
| Create any ATF step via MCP `create_record` | `sys_atf_step.inputs` is a compressed XML blob; REST API inserts an empty, non-functional step | Use SDK `Test()` API for server-side steps; use ServiceNow ATF UI for browser/portal steps |
| Create portal/browser ATF steps programmatically | Same compressed inputs barrier; applies to all catalog, form, and ESC navigation step configs | ServiceNow ATF UI — or Now Assist for Creator if the plugin is licensed and installed |
| Execute background scripts via MCP | Instance REST endpoint `/api/now/v1/scripted_rest_services/bg_script` not enabled by default on PDIs | Enable in System Properties, or use `SCRIPTING_ENABLED=true` in nowaikit config (instance endpoint must also be active) |
| Run ATF tests via MCP | Requires `ATF_ENABLED=true` in MCP server config AND ATF enabled on the instance | Run from the ServiceNow UI: `https://<instance>.service-now.com/sys_atf_test.do?sys_id=<test_sys_id>` |
| Now Assist for Test Creation via Claude Code | Now Assist for Creator is a separate licensed plugin; even with `NOW_ASSIST_ENABLED=true` in MCP config, no ATF generation tools appear if the plugin is not installed | Install Now Assist for Creator plugin; use its UI-based test generation (Claude cannot drive the UI) |

---

## OOB Module Testing (HRSD, CSM, ITSM)

Server-side functional testing of OOB modules is fully supported via the SDK path. The test record lives in your custom app scope; the steps target OOB tables.

```typescript
// Example: Test HR case creation from a custom scope
atf.server.recordInsert({
    table: 'sn_hr_core_case',
    fieldValues: {
        subject_person: '<sys_user_sys_id>',
        hr_service: '<hr_service_sys_id>',
        opened_for: '<sys_user_sys_id>',
    },
    enforceSecurity: false,
})
```

**What works:**
- Insert, validate, delete records in any OOB table
- Trigger and assert flow/workflow behavior
- Assert field population and state transitions
- Impersonate users with/without OOB roles

**What does not work:**
- Calling OOB Script Includes from a different scope (blocked by ServiceNow cross-scope access unless explicitly granted via `sys_scope_privilege`)
- Portal/browser steps for HRSD or CSM forms

---

## Decision Tree Summary

```
Does a now-sdk project exist?
├── YES
│   └── Use SDK path — handles custom AND OOB table testing (server-side)
│       └── After deploy: use MCP to create suite + schedule
│
└── NO — What do you need?
    ├── Server-side functional tests only
    │   └── SDK path (create a minimal now-sdk project targeting global scope)
    │       OR document as manual-only if no SDK project is warranted
    │
    ├── Suite + scheduling only (tests already exist on instance)
    │   └── MCP path — create_record + create_scheduled_job
    │
    └── Browser/portal/form UI steps
        ├── Now Assist for Creator installed?
        │   ├── YES → Use Now Assist ATF UI (prompt-driven; Claude guides the prompt)
        │   └── NO  → ServiceNow ATF UI only (manual; no programmatic path)
        └── (After manual step creation: use MCP to add to suite and schedule)
```

---

## Troubleshooting

### nowaikit MCP returning 502 on all calls
**Cause:** Wrong `SERVICENOW_INSTANCE_URL` in config, or instance is hibernated.
```bash
claude mcp get nowaikit   # verify URL
claude mcp remove nowaikit -s local
claude mcp add nowaikit -s local \
  -e SERVICENOW_INSTANCE_URL=https://<correct>.service-now.com \
  -e SERVICENOW_AUTH_METHOD=basic \
  -e SERVICENOW_BASIC_USERNAME=admin \
  -e "SERVICENOW_BASIC_PASSWORD=<password>" \
  -e WRITE_ENABLED=true -e SCRIPTING_ENABLED=true -e ATF_ENABLED=true \
  -- node /Users/<you>/nowaikit/dist/server.js
```
Then restart the Claude Code session.

### TestPlugin warning during build
**Cause:** `runServerSideScript` `script` field is not a plain string literal.
**Fix:** Remove `.trim()`, concatenation, template calls, or any variable from `script`.

### Deploy fails with "Could not determine app installation status"
**Fix:** `npm run deploy -- --reinstall`

### ATF_NOT_ENABLED from run_atf_test
**Fix:** Run from the ServiceNow UI — this is an MCP server config issue, not a test issue.

### Portal ATF step created via MCP has empty configuration
**Cause:** `sys_atf_step.inputs` compressed field — `create_record` inserts a structureless record.
**Fix:** Delete the step and recreate in the ServiceNow ATF UI.

### Cross-scope Script Include call fails in OOB module test
**Cause:** ServiceNow blocks cross-scope Script Include access by default.
**Fix:** Grant cross-scope access in ServiceNow: System Applications > Cross-Scope Access, or use `runServerSideScript` with `gs.setCurrentApplicationId()` to switch scope before calling the Script Include.

---

## Related Skills

- `ATF_SDK_SKILL.md` — detailed SDK-only reference with full code examples
- `ATF_SKILL.md` — MCP-only approach (requires proprietary Happy Technologies tools; not recommended)
- `ATF_SKILL_COMPARISON.md` — full evaluation of all three approaches with scores and findings
