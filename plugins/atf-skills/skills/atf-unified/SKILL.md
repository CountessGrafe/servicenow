---
name: atf-unified
version: 3.4.0
description: General-purpose ATF skill for any ServiceNow project. Covers server-side and UI testing via the now-sdk (Fluent), plus suite creation and scheduling via MCP. Auto-detects which path to use based on project structure and scope. Not project-specific — usable across HRSD, CSM, ITSM, custom scoped apps, and global scope.
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
    - get_atf_failure_insight
    - get_current_instance
complexity: intermediate
estimated_time: 15-45 minutes
---

# ATF Unified Skill — ServiceNow

The single ATF skill for any ServiceNow project. Covers server-side testing, UI/browser testing (catalog, form, navigation, Service Portal), suite creation, and scheduling. Auto-detects whether to use the SDK or MCP path.

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
│   │                       Browser runner required to execute (see below)
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

## SDK Path — Full Coverage

### Artifact → Test Pattern

| Artifact | What to assert | Step types |
|---|---|---|
| Script Include | Each public method: return value, edge cases (empty input, missing optional fields) | `server.runServerSideScript` (Jasmine) |
| Business Rule | Insert/update the trigger record; assert the side-effect | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Catalog Item — server-side E2E | Create test user → impersonate → submit via `GlideCatalogCart` → poll for output record → assert fields → revert impersonation → cleanup | `server.recordInsert`, `server.impersonate`, `server.runServerSideScript`, `server.recordDelete` |
| Catalog Item — UI-driven | Open the item in the browser → set variables via the real UI → order → validate output server-side | `catalog.openCatalogItem`, `catalog.setVariableValue`, `catalog.orderCatalogItem`, `server.recordValidation` |
| Catalog Item — Service Portal | Same as UI-driven but in ESC/portal context | `catalog_SP.openCatalogItem`, `catalog_SP.setVariableValue`, `catalog_SP.orderCatalogItem` |
| Platform Form | Open new/existing form → set fields → submit → validate record + field states (visible/mandatory/readonly) | `form.openNewForm`, `form.setFieldValue`, `form.submitForm`, `form.fieldStateValidation` |
| Flow / Subflow | Insert the trigger record; poll for the output record; assert fields | `server.recordInsert`, `server.recordValidation`, `server.recordDelete` |
| Table / Fields | Required fields exist with correct type and mandatory flag | `server.runServerSideScript` (GlideTableDescriptor) |
| ACL | Impersonate user with/without role; assert allowed/denied | `server.impersonate`, `server.recordInsert`, `server.recordValidation` |
| Navigation / Module visibility | Module appears for the right roles in the right navigator | `applicationNavigator.moduleVisibility` |
| Email notification | Outbound email triggered by the expected event with correct content | `email.validateOutboundEmail`, `email.validateOutboundEmailGeneratedByNotification` |
| OOB module record (HRSD, CSM, ITSM) | Insert case/record in OOB table from your custom scope; trigger workflow; assert state and field values | `server.recordInsert` (OOB table), `server.runServerSideScript`, `server.recordValidation` |

### Phase 1 — Read Before Writing

Never write a test before understanding the code under test.

```bash
Read src/fluent/<type>/<ArtifactName>.now.ts
Read src/server/<type>/<ArtifactName>.server.js
find src/fluent/tests -name "*.test.now.ts" | xargs grep -l "<ArtifactName>" 2>/dev/null
```

If a test already exists for this artifact, update the existing one rather than duplicating.

Confirm the target instance via `now.config.json` or `mcp get_current_instance`. Never assume.

After deploy, verify the deployed artifact is active on the instance before writing assertions:

```
mcp query_records(
    table: '<artifact_table>',    // sys_script (Business Rules), sys_script_include, sys_script_client, etc.
    query: 'sys_id=<artifact_sys_id>',
    fields: 'name,active,sys_scope'
)
```

A Business Rule or Script Include with `active: false` produces no deploy errors and no ATF errors — every assertion against its side-effects fails silently. If the flag is wrong after deploy, check whether the source has `active: true` and whether a previous manual edit set a `generation_source` that blocks SDK field updates.

### Phase 2 — Register IDs in keys.ts

Every `sys_atf_test` and every `sys_atf_step` needs a `Now.ID` entry in `src/fluent/generated/keys.ts` under the `explicit` block. Add all entries before writing the test file.

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

IDs are random 32-character hex strings, unique within the file.

### Phase 3 — Write Test Steps

**Location:** `src/fluent/tests/<ArtifactName>.test.now.ts`
**Naming convention:** `Test - <ArtifactName>` (add ` [UI]` or ` [Portal]` suffix when there are multiple variants)

#### 3.1 — Test skeleton

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
        // steps go here, in execution order
    }
)
```

#### 3.2 — server.runServerSideScript (Script Includes, schema, complex assertions)

Executes Jasmine on the server. Use for Script Include unit tests and any assertion that needs custom code.

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

> **Critical:** The `script` value must be a plain string literal. No `.trim()`, no concatenation, no template expressions, no variables. The SDK build plugin performs static analysis and silently drops the step if the value is not a literal — build succeeds but the step is missing from the output XML.

Available Jasmine matchers: `toBe`, `toEqual`, `toContain`, `toBeDefined`, `toBeTruthy`, `toBeGreaterThan`, `toBeLessThanOrEqualTo`, `not.toContain`, `not.toBeDefined`.

> **Wrapping is mandatory.** Every `expect()` call must live inside a `describe()` → `it()` block. A bare `expect()` at the top level of the script crashes the Jasmine runtime with a cryptic error that does not mention the missing wrapper.

Reference scoped Script Includes as `x_<scope_prefix>.<ClassName>()`.

#### 3.3 — server.recordInsert / recordValidation / recordDelete (CRUD)

```typescript
const inserted = atf.server.recordInsert({
    $id: Now.ID['test-my-artifact-step-insert'],
    description: 'Create a test record with known field values',
    table: 'x_<scope_prefix>_<table_name>',
    fieldValues: {
        field_one: 'ATF test value',
        field_two: 'another value',
    },
    enforceSecurity: false,
})

atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate'],
    description: 'Assert the record contains the expected values',
    table: 'x_<scope_prefix>_<table_name>',
    recordId: inserted.record_id,
    fieldValues: 'field_oneCONTAINSATF test value^field_twoSTARTSWITHanother',
    enforceSecurity: false,
})

atf.server.recordDelete({
    $id: Now.ID['test-my-artifact-step-delete'],
    description: 'Remove the test record',
    table: 'x_<scope_prefix>_<table_name>',
    recordId: inserted.record_id,
    enforceSecurity: false,
})
```

`fieldValues` for `recordValidation` is a ServiceNow encoded query string:

| Operator | Syntax |
|---|---|
| Equals | `fieldEQvalue` |
| Contains | `fieldCONTAINSvalue` |
| Starts with | `fieldSTARTSWITHvalue` |
| Greater than | `fieldGTvalue` |
| Is not empty | `fieldISNOTEMPTY` |

Always end with `recordDelete` for every record inserted. Never leave test data on the instance.

#### 3.4 — server.impersonate (ACLs, user context)

```typescript
atf.server.impersonate({
    $id: Now.ID['test-my-artifact-step-impersonate'],
    description: 'Switch to a user without the required role',
    user: '<sys_id>',
})
```

> **Critical:** `user` only accepts a **sys_id** — never a username string like `'admin'`. Passing a username causes a runtime failure: "User with sys_id 'admin' does not exist". To impersonate a dynamically created user, pass `insertedUser.record_id`. To revert to admin, use sys_id `6816f79cc0a8016401c5a33be04be441` — this is the OOB admin user, stable across all ServiceNow instances.

> **The impersonated user has no roles.** After `impersonate()`, the session has zero granted roles — nothing is inherited from admin. This causes silent failures: ACL-protected table reads return empty, reference-qualified catalog variables fail to populate, and any Business Rule that calls `gs.hasRole()` takes the deny branch. These appear as wrong field values or false assertions, not as explicit ATF errors.
>
> Grant the required roles immediately after impersonation with a `recordInsert` step targeting `sys_user_has_role`, and revoke with `recordDelete` before cleanup:
>
> ```typescript
> atf.server.recordInsert({
>     $id: Now.ID['test-my-artifact-step-grant-role'],
>     description: 'Grant required role to test user so ACLs pass during UI/catalog steps',
>     table: 'sys_user_has_role',
>     fieldValues: {
>         user: testUser.record_id,
>         role: '<role_sys_id>',
>     },
>     enforceSecurity: false,
> })
> ```
>
> Use `recordInsert` (not `runServerSideScript`) — dedicated step types execute in admin context and bypass the cross-scope restriction that blocks scoped-app scripts from writing to `sys_user_has_role`.

#### 3.5 — atf.catalog (catalog item — standard UI)

Tests the catalog item the way users experience it in the browser. Requires a browser runner to execute (see Browser Runner Requirements below).

```typescript
atf.catalog.openCatalogItem({
    $id: Now.ID['test-my-artifact-step-open'],
    description: 'Open the catalog item in the browser',
    catalogItem: '<catalog_item_sys_id>',
})

atf.catalog.setVariableValue({
    $id: Now.ID['test-my-artifact-step-set-vars'],
    description: 'Fill in the catalog item variables',
    catalogItem: '<catalog_item_sys_id>',
    variableValues: 'IO:<variable_sys_id>=<value>^IO:<variable_sys_id>=<value>^EQ',
})

const order = atf.catalog.orderCatalogItem({
    $id: Now.ID['test-my-artifact-step-order'],
    description: 'Submit the catalog item and capture the request sys_id',
    assert: 'form_submitted_to_server',
})

atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate-output'],
    description: 'Assert the output record was created with expected values',
    table: '<output_table>',
    recordId: order.request_id,
    fieldValues: 'fieldCONTAINSexpected value',
})
```

> **Variable format:** `IO:<sys_id>=<value>` entries joined with `^` and ending with `^EQ`. Look up variable sys_ids from `item_option_new` where `cat_item=<catalog_item_sys_id>`.

**Record Producer (Standard UI path — creates a record directly, e.g. `sn_hr_core_case`):**

Use `openRecordProducer` — NOT `openCatalogItem`. **Parameter name differs by surface:** Standard UI uses `catalogItem:`; the Service Portal path (section 3.6) uses `recordProducer:`. Copying the portal pattern to Standard UI causes a TypeScript build error.

```typescript
atf.catalog.openRecordProducer({
    $id: Now.ID['test-my-artifact-step-open-rp'],
    description: 'Open the record producer in the standard UI',
    catalogItem: '<sc_cat_item_producer_sys_id>',  // NOTE: catalogItem (not recordProducer — that's portal-only)
})

atf.catalog.setVariableValue({
    $id: Now.ID['test-my-artifact-step-set-vars-rp'],
    description: 'Fill in the record producer variables',
    catalogItem: '<sc_cat_item_producer_sys_id>',
    variableValues: 'IO:<variable_sys_id>=<value>^IO:<variable_sys_id>=<value>^EQ',
})

const submission = atf.catalog.submitRecordProducer({
    $id: Now.ID['test-my-artifact-step-submit-rp'],
    description: 'Submit the record producer and capture the created record sys_id',
    assert: 'form_submitted_to_server',
})

// submission.record_id is the sys_id of the created record (e.g. sn_hr_core_case)
```

> **`assert: 'form_submitted_to_server'` only confirms the form reached the server — it does NOT confirm the record producer's Script field ran to completion.** A script error in the producer produces an empty or partially populated output record, not an ATF step failure. Always pair with a `server.recordValidation` step to assert key output fields.

#### 3.6 — atf.catalog_SP (catalog item or record producer — Service Portal / ESC)

Same as `atf.catalog` but executes in the Service Portal / Employee Center context. Use when the catalog item or record producer is delivered through ESC.

**`portal` and `page` must be sys_ids, not string names.** The ATF runtime resolves them as object references — it reads `portal.url_suffix` and `page.id` from the loaded records. Passing a string like `'esc'` stores it as-is in the XML and the runtime treats it as a sys_id lookup, which returns null and crashes. Since ESC is an OOB portal installed from ServiceNow's system updates, its sys_id is consistent across all instances of the same release.

**Common OOB sys_ids (consistent across instances):**

| Record | url_suffix / page id | sys_id |
|---|---|---|
| Employee Center portal | `esc` | `70cd9f3b734b13001fdae9c54cf6a72f` |
| ESC catalog item / record producer page | `esc_sc_cat_item` | `c0728d1373675300c629e1e54cf6a7b3` |
| Standard Service Portal | `sp` | `81b75d3147032100ba13a5554ee4902b` |
| SP catalog item page | `sc_cat_item` | `9f12251147132100ba13a5554ee490f4` |

**Regular catalog item (not a Record Producer):**

```typescript
atf.catalog_SP.openCatalogItem({
    $id: Now.ID['test-my-artifact-step-open-sp'],
    description: 'Open the catalog item in the Employee Center portal',
    catalogItem: '<catalog_item_sys_id>',
    portal: '70cd9f3b734b13001fdae9c54cf6a72f',  // ESC portal sys_id
    page: 'c0728d1373675300c629e1e54cf6a7b3',     // esc_sc_cat_item page sys_id
})

atf.catalog_SP.setVariableValue({
    $id: Now.ID['test-my-artifact-step-set-vars-sp'],
    description: 'Fill in the catalog item variables in the portal context',
    catalogItem: '<catalog_item_sys_id>',
    variableValues: 'IO:<variable_sys_id>=<value>^IO:<variable_sys_id>=<value>^EQ',
})

atf.catalog_SP.orderCatalogItem({
    $id: Now.ID['test-my-artifact-step-order-sp'],
    description: 'Submit the catalog item through the portal',
    assert: 'form_submitted_to_server',
})
```

**Record Producer (creates a record directly, e.g. sn_hr_core_case):**

Use `openRecordProducer` / `submitRecordProducer` — NOT `openCatalogItem` / `orderCatalogItem`. The parameter for the item sys_id is `recordProducer`, not `catalogItem`.

```typescript
atf.catalog_SP.openRecordProducer({
    $id: Now.ID['test-my-artifact-step-open-sp'],
    description: 'Open the record producer in the Employee Center portal',
    recordProducer: '<sc_cat_item_producer_sys_id>',  // NOTE: recordProducer, not catalogItem
    portal: '70cd9f3b734b13001fdae9c54cf6a72f',
    page: 'c0728d1373675300c629e1e54cf6a7b3',
})

atf.catalog_SP.setVariableValue({
    $id: Now.ID['test-my-artifact-step-set-vars-sp'],
    description: 'Fill in the record producer variables',
    catalogItem: '<sc_cat_item_producer_sys_id>',
    variableValues: 'IO:<variable_sys_id>=<value>^IO:<variable_sys_id>=<value>^EQ',
})

const submission = atf.catalog_SP.submitRecordProducer({
    $id: Now.ID['test-my-artifact-step-submit-sp'],
    description: 'Submit the record producer and capture the created record sys_id',
    assert: 'form_submitted_to_server',
})

// submission.record_id is the sys_id of the created record (e.g. sn_hr_core_case)
atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate-sp'],
    description: 'Assert the output record was created',
    table: '<output_table>',
    recordId: submission.record_id,
    fieldValues: 'opened_byISNOTEMPTY',
    enforceSecurity: false,
})
```

`atf.catalog_SP` also exposes order guide methods: `openOrderGuide`, `navigatewithinOrderGuide`, `validateOrderGuideItem`, `reviewOrderGuideSummary`, and multi-row variable set methods.

#### 3.7 — atf.form (platform form — standard UI)

Tests platform forms (incident, change, hr_case, custom tables, etc.).

```typescript
atf.form.openNewForm({
    $id: Now.ID['test-my-artifact-step-open-form'],
    description: 'Open a new form for the target table',
    table: '<table_name>',
    formUI: 'standard_ui',
})

atf.form.setFieldValue({
    $id: Now.ID['test-my-artifact-step-set-fields'],
    description: 'Fill in the required fields',
    table: '<table_name>',
    fieldValues: { field_one: 'test value', field_two: 'another value' },
    formUI: 'standard_ui',
})

atf.form.fieldStateValidation({
    $id: Now.ID['test-my-artifact-step-field-state'],
    description: 'Assert which fields are visible, mandatory, and read-only',
    table: '<table_name>',
    visible: ['field_one', 'field_two'],
    mandatory: ['field_one'],
    notReadOnly: ['field_one', 'field_two'],
    formUI: 'standard_ui',
})

const submitted = atf.form.submitForm({
    $id: Now.ID['test-my-artifact-step-submit'],
    description: 'Submit the form and capture the created record sys_id',
    assert: 'form_submitted_to_server',
    formUI: 'standard_ui',
})

atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate'],
    description: 'Assert the record was saved with correct field values',
    table: '<table_name>',
    recordId: submitted.record_id,
    fieldValues: 'field_oneCONTAINStest value',
})
```

**formUI values:** `standard_ui`, `service_operations_workspace`, `asset_workspace`, `cmdb_workspace`.

#### 3.8 — atf.form_SP (platform form — Service Portal)

Same as `atf.form` but in Service Portal context. Includes the additional `openServicePortalPage` method and `portal` / `page` properties on all other methods.

#### 3.9 — atf.applicationNavigator (navigation / module visibility)

```typescript
atf.applicationNavigator.moduleVisibility({
    $id: Now.ID['test-my-artifact-step-nav'],
    description: 'Verify the target module is visible in the navigation',
    navigator: 'polaris',
    visibleModules: ['<module_sys_id>'],
    notVisibleModules: [],
})

atf.applicationNavigator.navigateToModule({
    $id: Now.ID['test-my-artifact-step-nav-go'],
    description: 'Navigate to the target module',
    module: '<module_sys_id>',
})
```

**navigator values:** `polaris` (current default), `ui16`, `ui15`.

#### 3.10 — atf.email (email notification testing)

```typescript
atf.email.validateOutboundEmail({
    $id: Now.ID['test-my-artifact-step-email'],
    description: 'Assert that an outbound email matching the criteria was sent',
    conditions: 'subjectCONTAINSExpected subject^recipientsCONTAINS<email>',
})

atf.email.generateInboundEmail({
    $id: Now.ID['test-my-artifact-step-inbound'],
    description: 'Generate an inbound email to trigger the inbound action',
    from: '<test_user_email>',
    to: '<instance_inbound_email>',
    subject: 'Test inbound',
    body: 'Test body content',
})
```

#### 3.11 — Step output chaining

Every step that creates or locates a record returns an output object. Reference its properties in subsequent steps to avoid hardcoding sys_ids — this is the recommended pattern for connecting setup → action → assert.

| Step type | Output property | Use in |
|---|---|---|
| `server.recordInsert` | `.record_id` | `recordValidation.recordId`, `recordDelete.recordId`, `impersonate.user` |
| `catalog.orderCatalogItem` | `.request_id` | `recordValidation.recordId` on `sc_request` |
| `catalog_SP.orderCatalogItem` | `.request_id` | Same |
| `catalog.submitRecordProducer` | `.record_id` | `recordValidation.recordId` on the output table |
| `catalog_SP.submitRecordProducer` | `.record_id` | Same |
| `form.submitForm` | `.record_id` | `recordValidation.recordId` |

Template literals embedding `${step.record_id}` **do resolve at runtime** — the SDK compiles the reference into a step-output token that the ATF runtime resolves at execution time. This is the dominant chaining pattern in multi-step tests. Do not concatenate strings manually.

```typescript
const testUser = atf.server.recordInsert({
    $id: Now.ID['test-my-artifact-step-create-user'],
    description: 'Create an isolated test user for this test run',
    table: 'sys_user',
    fieldValues: { user_name: 'atf.test.user', active: 'true' },
    enforceSecurity: false,
})

// Template literal chaining — ${step.record_id} compiles to a runtime-resolved token
atf.server.recordValidation({
    $id: Now.ID['test-my-artifact-step-validate'],
    description: 'Assert the record was created',
    table: 'sys_user',
    recordId: testUser.record_id,
    fieldValues: `sys_id=${testUser.record_id}^user_nameSTARTSWITHatf.test`,
    enforceSecurity: false,
})

atf.server.impersonate({
    $id: Now.ID['test-my-artifact-step-impersonate'],
    description: 'Impersonate the test user',
    user: testUser.record_id,
})

atf.server.recordDelete({
    $id: Now.ID['test-my-artifact-step-delete-user'],
    description: 'Clean up the test user',
    table: 'sys_user',
    recordId: testUser.record_id,
    enforceSecurity: false,
})
```

### Phase 4 — Build & Verify XML

```bash
npm run build
```

**Expected output:** `Build completed successfully` with no warnings.

**If you see:** `Plugin "TestPlugin" failed to transform "CallExpressionShape" shape into record`
→ A `runServerSideScript` step has a non-literal `script` value. Remove `.trim()`, concatenation, or any variable reference.

```bash
find dist/app -name "sys_atf_test_*.xml" -o -name "sys_atf_step_*.xml"
```

There must be one `sys_atf_test_*.xml` per test and one `sys_atf_step_*.xml` per step. A missing step file means the build silently dropped it.

### Phase 5 — Deploy

```bash
npm run deploy
```

If this fails with `Could not determine app installation status`:

```bash
npm run deploy -- --reinstall
```

`--reinstall` is the reliable deploy path when the standard install poll times out.

### Phase 6 — Run & Self-Heal

```
mcp run_atf_test(sys_id: '<test_sys_id>')
mcp run_atf_suite(sys_id: '<suite_sys_id>')
```

If `ATF_NOT_ENABLED`: run from the ServiceNow UI — `sys_atf_test.do?sys_id=<test_sys_id>` for a single test, `sys_atf_test_suite.do?sys_id=<suite_sys_id>` and click Run for a suite.

**For UI tests:** Ensure a browser runner is available before running (see Browser Runner Requirements below).

**Finding result sys_ids for failure insight:** Query `sys_atf_test_suite_result` filtered by `test_suite=<suite_sys_id>` to get the suite result, then `sys_atf_test_result` filtered by `parent=<suite_result_sys_id>` to get individual test results. Pass a `sys_atf_test_result` sys_id to `get_atf_failure_insight`.

> **On PDIs and dev instances:** Prefer the UI's **Run Test Suite** button over MCP-triggering the scheduled job. `mcp trigger_scheduled_job` sets `next_action=now` but the background scheduler tick on PDIs is unreliable — waits of 90+ seconds with no execution are normal. The Run Test Suite button invokes the runner directly, without waiting for the scheduler.

**Self-healing loop (repeat until green):**

1. `mcp get_atf_failure_insight(result_sys_id: '<result_sys_id>')` — get the failure detail
2. Identify exactly which assertion failed and the actual vs expected value
3. Fix the source `.now.ts` file
4. Rebuild → redeploy → re-run

Stop after 3 iterations on the same root cause. Report the exact failure and every fix attempted, then ask the user how to proceed.

### Phase 7 — Suite + Schedule

The SDK `Test()` API creates individual tests. Suites, suite memberships, and scheduled jobs can be authored with the SDK's `Record()` API — **this is the preferred approach** because it keeps them version-controlled alongside the tests and they survive `--reinstall`. MCP is the fallback for projects with no SDK setup.

**Preferred: SDK `Record()` path**

Register IDs in `keys.ts` first:

```typescript
'suite-my-artifact': { table: 'sys_atf_test_suite', id: '<32-char-hex>' }
'suite-my-artifact-test-1': { table: 'sys_atf_test_suite_test', id: '<32-char-hex>' }
'schedule-my-artifact-nightly': { table: 'sysauto_script', id: '<32-char-hex>' }
```

Then in a `.now.ts` file (e.g. `src/fluent/suites/MyArtifactSuite.now.ts`):

```typescript
import { Record } from '@servicenow/sdk/core'

export const MyArtifactSuite = Record({
    $id: Now.ID['suite-my-artifact'],
    table: 'sys_atf_test_suite',
    data: {
        name: 'Suite — MyArtifact',
        active: true,
    },
})

// One Record per test; increment order by 100
// Now.ID[key].id is declared in keys.ts and should resolve at build time inside Record({ data }).
// Verify this compiles in your SDK version before adopting it — if the build rejects it,
// fall back to the literal sys_id string from keys.ts.
export const MyArtifactSuiteTest1 = Record({
    $id: Now.ID['suite-my-artifact-test-1'],
    table: 'sys_atf_test_suite_test',
    data: {
        test_suite: Now.ID['suite-my-artifact'].id,
        test: Now.ID['test-my-artifact'].id,
        order: 100,
    },
})

// Nightly schedule — Now.ID[key].id bakes the sys_id into the script at build time
export const MyArtifactSchedule = Record({
    $id: Now.ID['schedule-my-artifact-nightly'],
    table: 'sysauto_script',
    data: {
        name: 'Scheduled — Suite MyArtifact (Nightly)',
        script: `var gr = new GlideRecord('sys_atf_test_suite'); gr.get('${Now.ID['suite-my-artifact'].id}'); new SncATFTestSuiteRunner(gr).run();`,
        run_type: 'daily',
        run_time: '1970-01-01 06:00:00',
        active: true,
    },
})
```

**Fallback: MCP (no SDK project)**

Use MCP only when no `now-sdk` project exists to commit to. MCP-created suites and scheduled jobs are wiped on `npm run deploy -- --reinstall` — they do not live in the SDK XML and must be recreated after every reinstall.

```
mcp create_record(
    table: 'sys_atf_test_suite',
    fields: {
        name: 'Suite - <ArtifactName>',
        description: '<what this suite covers>',
        active: 'true',
        sys_scope: '<scope_sys_id>'
    }
)

# Then for each test (increment order by 100):
mcp create_record(
    table: 'sys_atf_test_suite_test',
    fields: {
        test_suite: '<suite_sys_id>',
        test: '<test_sys_id>',
        order: '100'
    }
)

mcp create_scheduled_job(
    name: 'Scheduled - Suite <ArtifactName> (Nightly)',
    script: "var gr = new GlideRecord('sys_atf_test_suite');\ngr.get('<suite_sys_id>');\nnew SncATFTestSuiteRunner(gr).run();",
    run_type: 'daily',
    run_time: '1970-01-01 06:00:00',
    active: true
)
```

---

## MCP Path (No SDK Project)

Use when no `now-sdk` project exists, or when the artifact is in global scope and you only need suite/scheduling.

| Action | MCP tool |
|---|---|
| Check existing tests/suites | `query_records` on `sys_atf_test` / `sys_atf_test_suite` |
| Create suite | `create_record` on `sys_atf_test_suite` |
| Add test to suite | `create_record` on `sys_atf_test_suite_test` |
| Schedule suite | `create_scheduled_job` |
| Run test | `run_atf_test` (requires `ATF_ENABLED=true` in MCP config) |
| Run suite | `run_atf_suite` (requires `ATF_ENABLED=true` in MCP config) |
| Root-cause failure | `get_atf_failure_insight` |

**MCP cannot create individual ATF steps** — see Hard Limits.

---

## Browser Runner Requirements

UI-based ATF steps (`atf.catalog`, `atf.form`, `atf.catalog_SP`, `atf.form_SP`, `atf.applicationNavigator`) execute in a real browser. ServiceNow provides two runner options. The Client Test Runner is built into every instance; the Cloud Runner is an optional paid Store application.

### ATF Client Test Runner — built into every instance

**How it works:**
- Open `https://<instance>.service-now.com/atf_test_runner.do` in a browser tab
- The tab connects to the instance and executes UI test steps when a test runs
- Works for on-demand runs (Run Test button, MCP-triggered) **and** scheduled runs, as long as the tab remains open and active

**What it requires:**
- A logged-in browser session on the instance
- The browser tab to stay open for the duration of the run (and ongoing for scheduled tests)
- No plugin activation, no licensing — works on PDIs and any standard instance

**Practical considerations:**
- Tab must be in the foreground for full speed — browsers throttle background tabs
- Long-running sessions can accumulate browser memory pressure; restart the tab periodically for stability
- Screenshots and pixel-based assertions require browser zoom at 100%
- If the tab crashes or is closed, in-progress runs fail and scheduled runs are skipped until the tab is reopened

**Suitable for:** development, on-demand validation, and scheduled runs where a dedicated machine can keep the tab open (e.g. a build-monitor VM with a browser tab pinned).

### ATF Cloud Runner — paid Store application, hosted by ServiceNow

**What it is:**
- ServiceNow Store application: "ATF Test Generator and Cloud Runner" (Store SKU: `sn_atf_tg`)
- Executes UI test steps on a ServiceNow-hosted headless browser
- Truly headless — no browser tab anywhere

**What it requires:**
- A paid subscription to the Cloud Runner application
- Installation by a ServiceNow administrator via System Applications
- **Not available on PDIs** — Personal Developer Instances lack the paid subscription
- **Not available to on-premises customers** — requires connection to ServiceNow's cloud infrastructure

Once installed, it is transparent to test code — the platform automatically routes UI steps to the Cloud Runner whenever a test runs, whether triggered from the UI, via MCP, or on a schedule. Test files do not change.

**Suitable for:** production CI pipelines, customers with paid subscriptions, scheduled suites where keeping a browser tab open is impractical.

### Which one should you use?

| Situation | Runner |
|---|---|
| PDI or unpaid instance | Client Test Runner (only option) |
| Paid instance, on-demand testing | Client Test Runner is sufficient |
| Paid instance, scheduled CI | Cloud Runner if subscribed; otherwise Client Test Runner on a dedicated machine |
| On-premises ServiceNow | Client Test Runner only (Cloud Runner not available) |

**How to know which runner ran a test:** the result record on `sys_atf_test_result` includes the runner type. If a UI step is skipped or fails with "no runner available", neither option is active — open the Client Test Runner tab, or (paid instances only) install the Cloud Runner Store app.

---

## Hard Limits

| Limitation | Root cause | Workaround |
|---|---|---|
| Create UI/browser ATF steps via MCP `create_record` | `sys_atf_step.inputs` is a compressed XML blob; MCP REST inserts an empty, non-functional step | Use SDK `atf.catalog` / `atf.form` / `atf.catalog_SP` / `atf.form_SP` Fluent APIs — SDK build pipeline generates correct compressed inputs |
| Create any ATF step (any type) via MCP `create_record` | Same compressed inputs barrier; applies to server steps as well | Use SDK `Test()` API; or create steps in the ServiceNow ATF UI |
| Run ATF tests via MCP | Requires `ATF_ENABLED=true` in MCP server config AND ATF enabled on the instance | Run from the ServiceNow UI |
| Execute UI steps without an active runner | UI steps require a real browser. Client Test Runner tab not open AND Cloud Runner not installed/active | Open `<instance>/atf_test_runner.do` in a browser tab (works on any instance including PDIs, no paid subscription), or install the paid "ATF Test Generator and Cloud Runner" Store app (paid instances only) |
| Cross-scope Script Include calls in OOB module tests | ServiceNow blocks cross-scope Script Include access by default | Grant cross-scope access via `sys_scope_privilege`, or use `runServerSideScript` with `gs.setCurrentApplicationId()` |
| Cross-scope writes inside `runServerSideScript` | `runServerSideScript` executes in the artifact's app scope — operations on global protected tables (`sys_user`, `sys_user_has_role`, `sys_user_role`) hit the cross-scope access policy and silently fail or throw | Use dedicated step types (`recordInsert`, `recordDelete`) instead — they run in admin context, not app scope |

---

## OOB Module Testing (HRSD, CSM, ITSM)

Server-side functional testing of OOB modules is fully supported via the SDK path. The test record lives in your custom app scope; the steps target OOB tables directly.

```typescript
atf.server.recordInsert({
    $id: Now.ID['test-hr-case-creation-step-insert'],
    description: 'Create an HR case in the OOB hr_case table from a custom-scope test',
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
- Insert, validate, delete in any OOB table from your custom scope
- Trigger and assert flow/workflow behavior
- Assert field population and state transitions
- Impersonate users with/without OOB roles
- UI tests (`atf.form`, `atf.catalog`) targeting OOB forms and catalog items

**What does not work:**
- Calling OOB Script Includes from a different scope without explicit cross-scope grants

---

## Best Practices

### Test design
- One scenario per test — keep each test focused on a single behavior
- Edge cases required — every test must include at least one non-happy-path assertion (empty input, missing optional field, boundary value)
- No dependency on existing data — create everything you need with `recordInsert`, clean up with `recordDelete`
- Readable descriptions — every step needs a `description` that explains what it asserts

### Keys.ts hygiene
- Add all IDs before writing the test file
- Use descriptive key names: `test-<artifact>`, `test-<artifact>-step-<action>`
- Never reuse an existing ID for a new record

### Build hygiene
- Always verify `dist/app/` XML before deploying — a missing step file means the build dropped it
- Fix TestPlugin warnings immediately — they indicate steps that will be absent from the instance

### Data hygiene
- Prefix test data values with `ATF test:` so they are identifiable if cleanup fails
- Always end every test with `recordDelete` for every record inserted

### UI test hygiene
- Confirm a browser runner is available before running UI tests
- Combine UI steps with `atf.server.recordValidation` to assert backend state after a UI action
- Use `atf.server.impersonate` to set user context before UI steps — UI steps execute as the impersonated user
- After `impersonate()`, grant required roles via `recordInsert` on `sys_user_has_role` before any UI step — without this, ACL-controlled elements and reference fields will silently fail (see ACL Cascade Denial)

---

## Troubleshooting

### TestPlugin warning during build
**Cause:** `runServerSideScript` `script` field is not a plain string literal.
**Fix:** Remove `.trim()`, concatenation, template calls, or any variable from `script`.

### Step missing from dist/app after build
**Cause:** Build dropped it silently (usually the same root cause as above).
**Fix:** Check for the TestPlugin warning, fix the `script` literal, rebuild.

### Deploy fails with "Could not determine app installation status"
**Fix:** `npm run deploy -- --reinstall`.

### ATF_NOT_ENABLED from run_atf_test
**Fix:** Run from the ServiceNow UI. This is an MCP server config issue, not a test issue.

### UI step fails with "ResizeObserver loop completed with undelivered notifications"

**Cause:** This is benign browser noise. When a Service Portal / ESC page loads, many components resize simultaneously and the browser can't deliver all ResizeObserver callbacks in one animation frame. The page and g_form loaded successfully — the ATF runner just caught the browser's housekeeping message and treated it as a test failure.

**Fix:** In the failing step result in the ServiceNow ATF UI, click **"Add all client errors to warning/ignored list"**. This is a one-time action that registers this error pattern as a warning (not a failure) for future runs. Cannot be done via MCP.

### UI step fails with "Cannot read properties of undefined (reading 'url_suffix')"

**Cause:** The `portal` parameter was passed as a string (e.g. `'esc'`) instead of a sys_id. The ATF runtime resolves `portal` as an object reference and reads `portal.url_suffix` from it. When `'esc'` is passed, the runtime treats it as a sys_id lookup, gets null, and crashes on `null.url_suffix`.

**Fix:** Pass the sys_id of the `sp_portal` record, not the url_suffix string. For OOB portals, the sys_ids are consistent across instances — see the table in section 3.6.

### UI step fails with "Cannot read properties of undefined (reading 'id')"

**Cause:** Same issue as above but for the `page` parameter — the page string (e.g. `'sc_cat_item'`) is being resolved as a sys_id and not found.

**Fix:** Pass the sys_id of the `sp_page` record. For ESC catalog items/record producers, the page sys_id is `c0728d1373675300c629e1e54cf6a7b3` (`esc_sc_cat_item`).

### UI step skipped or "no runner available"
**Cause:** No browser runner is active.
**Fix:** Open `<instance>/atf_test_runner.do` in a browser tab and keep it open during the run — works on any instance including PDIs, no plugin or subscription needed. If you need headless execution and your instance has a paid ATF Cloud Runner subscription, install the "ATF Test Generator and Cloud Runner" Store application; otherwise, the Client Test Runner tab is the only option.

### UI step created via MCP create_record has no configuration
**Cause:** `sys_atf_step.inputs` is a compressed XML blob; MCP cannot populate it.
**Fix:** Do not use MCP `create_record` for ATF steps. Use the SDK `atf.*` Fluent APIs.

### Cross-scope Script Include call fails in OOB module test
**Fix:** Grant cross-scope access in System Applications > Cross-Scope Access, or call `gs.setCurrentApplicationId()` inside `runServerSideScript`.

---

## Common Failure Modes & Debugging

The Troubleshooting section above covers build and infrastructure issues. These patterns cover behavioral failures that appear as wrong assertion values or unexpected test results — harder to diagnose because no error message names the real cause.

### ACL Cascade Denial

**Symptom:** After `impersonate()`, reference fields are empty, catalog variables fail to populate, or a Business Rule silently takes the deny branch. Assertions fail with empty or wrong values.
**Root cause:** The impersonated user has zero roles — ATF does not copy any roles from the previous session.
**Fix:** Add a `recordInsert` step on `sys_user_has_role` immediately after `impersonate()`. Grant only the minimum roles required. Revoke with `recordDelete` before cleanup.

### Cross-Scope Cleanup Denial

**Symptom:** A `runServerSideScript` cleanup step that deletes `sys_user` records or modifies `sys_user_has_role` silently fails. Records are left on the instance after the test run.
**Root cause:** `runServerSideScript` executes in the artifact's app scope. Writes to global protected tables are blocked by the cross-scope access policy.
**Fix:** Replace `runServerSideScript` cleanup with `recordDelete` / `recordInsert` step types — these run in admin context, not app scope.

### Cleanup Hides Evidence

**Symptom:** A test fails partway through, cleanup runs anyway, and by the time you read the results there is no record to inspect on the instance.
**Root cause:** ATF continues executing subsequent steps even after a failure unless the test run is halted. Cleanup steps already queued run regardless.
**Fix (during debugging):** Temporarily comment out cleanup steps. Alternatively, prefix test data with a timestamp (`'ATF test: ' + new Date().toISOString()`) so orphaned records are identifiable if cleanup fails. For complex E2E tests, add a diagnostic `runServerSideScript` step immediately before cleanup that calls `gs.info('DEBUG fields: ' + gr.getDisplayValue())` on the record you want to inspect — the output appears in the instance system log.

### Bare Expect

**Symptom:** `runServerSideScript` step fails with a cryptic Jasmine runtime error. No line number. `expect()` calls looked correct in isolation.
**Root cause:** An `expect()` call is at the top level of the script string, outside a `describe()` → `it()` block.
**Fix:** Wrap every `expect()` in `describe('...', function() { it('...', function() { ... }); });`. The wrapper is not optional — Jasmine requires it.

### Submit Does Not Validate Script Completion

**Symptom:** `catalog.submitRecordProducer` or `catalog_SP.submitRecordProducer` passes with `assert: 'form_submitted_to_server'`, but the output record is missing fields or was not created at all.
**Root cause:** `form_submitted_to_server` only confirms the form reached the server. A script error in the record producer's Script field produces a partial or empty output record — not an ATF step failure.

**Common causes of mid-script failure:**
- **DateTime variable assignment** — assigning a DateTime-typed variable to a Date field (or vice versa) in the producer script throws at runtime, leaving all subsequent field assignments unexecuted. The record is created but most fields remain at their default values.
- **Reference field not resolved** — passing a display value where a sys_id is expected causes a silent no-op on that field.
- **Mandatory field skipped** — the producer script exits early without error if a mandatory field isn't supplied by the variable mapping.

**Fix:** Always follow `submitRecordProducer` with a `server.recordValidation` step. When the producer script may only partially complete (e.g. a DateTime type mismatch leaves some fields at defaults), use lenient assertions: only assert the fields the script definitely sets, plus an `ISNOTEMPTY` check on a field that only gets written if the script runs to completion. This catches the failure at the correct step without a fragile all-or-nothing assertion.

## Checklist

Before reporting the task complete, every item must be true:

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
- [ ] If applicable: suite created and scheduled

---

## References

- [ServiceNow SDK — Test()](https://docs.servicenow.com/csh?topicname=atf-test-now-ts.html&version=latest)
- [ATF Documentation](https://docs.servicenow.com/bundle/utah-application-development/page/administer/auto-test-framework/concept/automated-test-framework.html)
- [ATF Cloud Runner](https://docs.servicenow.com/bundle/utah-application-development/page/administer/auto-test-framework/concept/atf-cloud-runner.html)
- [now-sdk CLI reference](https://docs.servicenow.com/bundle/utah-application-development/page/build/servicenow-sdk/concept/sdk-overview.html)
