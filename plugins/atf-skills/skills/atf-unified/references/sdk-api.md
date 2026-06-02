# SDK Path — Authoring Reference

> On-demand reference for `atf-unified`. The core `SKILL.md` holds path selection, the 7-phase map, the
> Phase 6 self-heal contract, and the checklist. **Read this file when authoring SDK test steps** (Phases
> 1–5, the full `atf.*` step catalog) or when you need the MCP path, browser-runner, hard-limits, OOB, or
> best-practice detail. Phase 6 (Run & Self-Heal) lives in the core; Phase 7 (Suite + Schedule) is in
> `references/suite-schedule.md`.

---

## Artifact → Test Pattern

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

## Phase 1 — Read Before Writing

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

## Phase 2 — Register IDs in keys.ts

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

## Phase 3 — Write Test Steps

**Location:** `src/fluent/tests/<ArtifactName>.test.now.ts`
**Naming convention:** `Test - <ArtifactName>` (add ` [UI]` or ` [Portal]` suffix when there are multiple variants)

### 3.1 — Test skeleton

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

### 3.2 — server.runServerSideScript (Script Includes, schema, complex assertions)

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

### 3.3 — server.recordInsert / recordValidation / recordDelete (CRUD)

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

### 3.4 — server.impersonate (ACLs, user context)

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

### 3.5 — atf.catalog (catalog item — standard UI)

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

### 3.6 — atf.catalog_SP (catalog item or record producer — Service Portal / ESC)

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

### 3.7 — atf.form (platform form — standard UI)

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

### 3.8 — atf.form_SP (platform form — Service Portal)

Same as `atf.form` but in Service Portal context. Includes the additional `openServicePortalPage` method and `portal` / `page` properties on all other methods.

### 3.9 — atf.applicationNavigator (navigation / module visibility)

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

### 3.10 — atf.email (email notification testing)

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

### 3.11 — Step output chaining

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

## Phase 4 — Build & Verify XML

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

## Phase 5 — Deploy

```bash
npm run deploy
```

If this fails with `Could not determine app installation status`:

```bash
npm run deploy -- --reinstall
```

`--reinstall` is the reliable deploy path when the standard install poll times out.

> **Phase 6 — Run & Self-Heal** lives in the core `SKILL.md` (the canonical self-heal/report contract).
> **Phase 7 — Suite + Schedule** is in `references/suite-schedule.md`.

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
- After `impersonate()`, grant required roles via `recordInsert` on `sys_user_has_role` before any UI step — without this, ACL-controlled elements and reference fields will silently fail (see `references/troubleshooting.md` § ACL Cascade Denial)
