# Troubleshooting & Common Failure Modes

> On-demand reference for `atf-unified`. Read this file when a build, deploy, or test run fails. The first
> section covers build/infrastructure errors with explicit messages; the second covers **behavioral**
> failures that surface as wrong assertion values with no error naming the real cause.

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

**Fix:** Pass the sys_id of the `sp_portal` record, not the url_suffix string. For OOB portals, the sys_ids are consistent across instances — see the table in `references/sdk-api.md` § 3.6.

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
