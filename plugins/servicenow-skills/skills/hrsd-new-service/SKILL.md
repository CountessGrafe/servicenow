---
name: hrsd-new-service
description: Create an HRSD service on ServiceNow, building up from a plain HR Service to optional Record Producer, template, fulfillment flow, and Employee Center wiring. Each piece is added only when the service needs it. Requires now-sdk + Fluent. MCP is used where available. Custom table creation is out of scope — use a separate skill for that.
---

Read @hrsd-knowledge/SKILL.md before proceeding — it contains all HRSD platform patterns referenced below, including the cross-scope rules, trigger condition syntax, required HR Service fields, variable-type pitfalls, and the 6-step onboarding flow pattern. This skill is the *procedure*; `hrsd-knowledge` is the *reference*. Do not restate platform facts here — link to that file.

## How to use this skill

Not every HR service needs a Record Producer, a flow, an HR task, or user creation. Most are a plain HR Service record with manual fulfillment. **Build incrementally:**

1. **Always** create the HR Service first (Step 2), with `fulfillment_type` left at its default (`simple` / manual).
2. Then add only the pieces the service actually needs — each of Steps 3–6 opens with a **gate**. If the gate doesn't apply, skip the step.

Creating the HR Service first also means its sys_id exists before any flow is authored, so the flow's trigger condition can reference it and the flow is linked back afterward — there is no chicken-and-egg ordering problem.

```
Step 0    Bootstrap constants        (always)
Step 1    Gather + context check     (always)
Step 2    Create HR Service          (always — fulfillment_type = simple)
Step 3    Record Producer            (only if request-submitted)
Step 4    HR Service template        (only if defaults like group/priority needed)
Step 5    Fulfillment flow           (only if fulfillment is automated → flip to flow)
Step 6    Employee Center publishing (only if requestable in ESC)
Step 6.5  German translations        (always — after all English content is in place)
Step 7    ATF tests                  (always — scaled to what was built)
Step 8    Verify                     (always — rows conditional on what exists)
```

**Language rule:** implement everything in English first. Only after all English artifacts are deployed and verified (Steps 2–6) add German translations in Step 6.5. Never author German content in the same pass as the initial artifact — the English version is the source of truth.

## Step 0: Bootstrap instance constants

Before gathering anything, run the `@hrsd-bootstrap-instance/SKILL.md` procedure. It detects the active instance, loads a cached `reference_constants_<hostname>.md` if present, or queries and caches all stable sys_ids otherwise (badge, header configs, HR catalog, m2m content type, sn_hr_core scope, vendor prefix, `sys_user` access flags).

Read its pre-flight verdict:
- If it flags `sys_user.create_access = false`, note it — it determines flow scope in Step 5.
- If it flags a vendor prefix mismatch between `glide.appcreator.company.code` and the scoped app prefix, surface it as a blocker before writing any code.

Only proceed once bootstrap completes.

## Step 1: Gather the service definition + context-first check

**Context-first (global CLAUDE.md rule):** before writing any artifact (after Step 0 bootstrap), query `sn_hr_core_service` for an existing record with the same `name` / `value`. If one exists, decide with the user: update it, create a variant, or stop. Don't create a duplicate.

Then collect what's needed in a single turn where possible.

**Required for the HR Service itself:**
- Service name (human-readable display name) and scope prefix of the scoped app (e.g., `x_<company>_<app>`).
- `value`: derive as snake_case of the service name (don't ask).
- `topic_detail`: pick the best match; query `sn_hr_core_topic_detail` if the cache has nothing suitable. (COE is derived from `topic_detail → topic_category → coe` — never set COE directly. See hrsd-knowledge.)
- **`service_table`**: derives from the COE — do NOT hardcode `sn_hr_core_case`. After selecting `topic_detail`, resolve the COE and its case table:
  ```
  query_records('sn_hr_core_topic_detail', 'sys_id=<topic_detail_sys_id>', 'topic_category')
  query_records('sn_hr_core_topic_category', 'sys_id=<topic_category_sys_id>', 'coe')
  query_records('sn_hr_core_coe', 'sys_id=<coe_sys_id>', 'case_table')
  ```
  Use the returned `case_table` value everywhere `service_table` and the RP's `table` field appear. Common values: `sn_hr_core_case` (general), `sn_hr_core_case_benefits`, `sn_hr_core_case_payroll`, etc. If `case_table` is empty on the COE record, fall back to `sn_hr_core_case` and note it.

**Decide which optional artifacts apply** (this drives which later steps run):
- Is the service **request-submitted** by an employee? → needs a Record Producer (Step 3).
- Does it need **default field values** (assignment group, priority)? → needs an HR Service template (Step 4).
- Is fulfillment **automated**? → needs a flow (Step 5). If yes, does the flow create/modify `sys_user` or other protected global tables? (Determines flow scope.)
- Should it be **requestable in Employee Center**? → ESC publishing (Step 6).

**Clarify-when-unspecified (ask, don't guess) — confirm these even if the story is silent:**
- **Who can submit this service (RP user criteria)?** — If there is a Record Producer, ask which employees can see/submit it. This maps to the RP's `Available For` / `Not Available For` `user_criteria` related list (Service Catalog concept). Wire it in Step 3, not Step 6. Only default to "all employees" after confirming.
- **Who can the service be assigned/visible to internally (HR criteria)?** — Optional. If not specified, skip `hr_criteria` on the HR Service (leave empty = no restriction). Only ask if the story explicitly restricts which HR agents or COEs can see the case.
- `subject_person_access` — should the subject person see their own case? (Default `true`.)
- `header_config_opened_for` / `header_config_subject_person` — confirm the OOB defaults from the bootstrap cache, or override per the story.
- `case_options` — the skip-automation-style options. If unmentioned they're likely not relevant, but confirm rather than assume.

**Optional fields to offer (skip if not provided):** `case_options`, `hr_criteria`, `fulfillment_instructions`, `case_creation_service_config`. (Template is handled as a prompted gate in Step 4.)

## Step 2: Always — create the HR Service (manual fulfillment)

This record is the spine; everything else attaches to it. Create it first, with `fulfillment_type` at its default `simple` (manual) — `producer` and `flow` stay empty until later steps fill them.

**Pre-flight:**
- **Confirm the target instance** — all MCP operations target it.
- **Ensure an update set scoped to the app is active.** Query the current set via MCP `get_current_update_set`. `create_update_set` uses whichever scope is active in the admin session — verify the scope after creating, or create with explicit scope context. (See memory: update set must match the table's scope.)
- **Confirm the SDK project exists** at the expected path. If not:
  ```bash
  npx @servicenow/sdk init --appName "<ServiceName>" --packageName "<scope_name>" --scopeName "<scope_prefix>" --template base
  npm install
  npm run types
  ```
  `--packageName` is required to avoid the interactive prompt.

**Create the record** — there is no MCP tool for `sn_hr_core_service`, so use SDK `Record()`. Populate every required field from hrsd-knowledge "HR Service: required fields at creation":

```typescript
import '@servicenow/sdk/global'
import { Record } from '@servicenow/sdk/core'

Record({
    $id: Now.ID['<service-id>'],
    table: 'sn_hr_core_service',
    data: {
        name: '<HR Service Name>',
        value: '<hr_service_value>',
        service_table: '<COE case_table from Step 1>',  // create-only — silently ignored on update. Derive from topic_detail → COE, do NOT hardcode sn_hr_core_case.
        topic_detail: '<topic detail sys_id>',
        fulfillment_type: 'simple',                // default/manual — flipped to 'flow' in Step 5 if needed
        header_config_opened_for: '<sys_id from bootstrap>',
        header_config_subject_person: '<sys_id from bootstrap>',
        subject_person_access: true,               // per Step 1 answer
        badge: '<HR badge sys_id from bootstrap>', // NOT the string "HR"
        active: true,
        // hr_criteria: '<sn_hr_core_criteria sys_id>' — optional, only if the story restricts internal HR visibility
        // include any other optional fields provided
    },
})
```

**`service_table` and `fulfillment_type` MUST be in this create call** — `service_table` is silently ignored on update. If you forget it the first time, delete the record and redeploy.

Deploy (`npm run deploy`), then **query the record back and capture its sys_id** — Steps 3, 5, and the flow trigger condition all need it. Verify `service_table`, both `header_config_*`, `subject_person_access`, `badge`, `active` are populated.

## Step 3: Record Producer — *skip unless the service is request-submitted*

Build the RP in `src/fluent/catalog/<service-name>-rp.now.ts`. Follow hrsd-knowledge for the mandatory `script` field, variable-type pitfalls, and the `readOnly`+`mandatory` constraint.

```typescript
import '@servicenow/sdk/global'
import {
    CatalogItemRecordProducer,
    ReferenceVariable,
    SingleLineTextVariable,
    SelectBoxVariable,
    MultiLineTextVariable,
    // import EVERY variable type you actually use — YesNo, Date, ListCollector, etc.
    // omitting an import for a type used below fails the build (TS).
} from '@servicenow/sdk/core'

export const <RPConstName> = CatalogItemRecordProducer({
    $id: Now.ID['<rp-id>'],
    name: '<RP Name>',
    table: '<COE case_table from Step 1>',   // must match the HR Service service_table — derive from topic_detail → COE
    shortDescription: '<short description>',
    description: '<description>',
    // mandatory — without it the case is missing subject_person/opened_for/short_description.
    // Pass as a plain string (see hrsd-knowledge), never a typed function.
    script: 'new sn_hr_core.hr_ServicesUtil(current, gs).createCaseFromProducer(producer, cat_item.sys_id);',
    variables: {
        employee: ReferenceVariable({
            question: 'Employee',
            referenceTable: 'sys_user',
            order: 1,
            readOnly: true,                          // do NOT also set mandatory: true
            defaultValue: 'javascript:gs.getUserID()',
        }),
        // add remaining variables from the user's definition
    },
})
```

**What `createCaseFromProducer` handles automatically:** `short_description`, `opened_for`, and `subject_person` (set from the `employee` variable if present, or left for the flow to set). Do not duplicate these in the flow.

**Other field mappings from RP variables to the HR case or other records:** if the story requires RP variable values to populate specific HR case fields (e.g., a department variable → `sn_hr_core_case.department`) or other records, implement those mappings as Update Record actions in the fulfillment flow (Step 5). Ask about this when gathering variables: "does any variable need to populate a specific field on the case or another record?"

Notes:
- `employee` pre-filled with `gs.getUserID()` is standard for self-service. For onboarding-style forms (filled FOR a new hire), omit the employee field — the flow creates the new `sys_user` instead.
- Number inputs → `SingleLineTextVariable` (no NumberVariable exists). `RichTextLabelVariable` takes `richText` only (no `question`). ListCollector uses `listTable`. See hrsd-knowledge "SDK variable type pitfalls".

**Wire user criteria (from Step 1):** if the audience is not "all employees", create `sc_user_criteria_mtom` (Available For) and/or `sc_no_user_criteria_mtom` (Not Available For) records linking the RP sys_id to the appropriate `user_criteria` sys_ids. This is what restricts who can see and submit the RP — it is a Service Catalog concept, separate from the HR Service `hr_criteria`. Do this after deploying the RP so its sys_id is known.

**Link the RP to the HR Service** — add `producer: \`${<RPConstName>}\`` to the Step 2 `Record()` (import the const), redeploy, and verify the `producer` field is populated.

## Step 4: HR Service template — *skip unless default field values are needed*

Ask: **should this service preset any fields on the created case** — e.g., assignment group, priority, or state? If no, skip. If yes, collect which fields and values to preset, then create the template.

Templates are typically service-specific (created for this service, not reused from elsewhere). HR case templates live in `sn_hr_core_template` (extends `sys_template`). Create via MCP `create_record`:

```
mcp__servicenow-mcp__create_record(
    table: 'sn_hr_core_template',
    data: {
        name: '<Service Name> Template',
        table: '<COE case_table from Step 1>',
        template: 'assignment_group=<sys_id>^priority=3^...'  // encoded query of field=value pairs to preset
    }
)
```

Capture the returned sys_id. **Update-set note:** this record is created directly on the instance via MCP — ensure your scoped update set is active before creating it, or capture it manually in the update set afterward so it transports to downstream instances.

Then add `template: '<sys_id>'` to the Step 2 `Record()` and redeploy. Verify the HR Service record has `template` populated and the template record itself has the correct field preset values.

## Step 5: Fulfillment flow — *skip unless fulfillment is automated*

If the service is fulfilled manually, leave `fulfillment_type: 'simple'` and skip to Step 7.

### 5a. Decide the flow scope

| Does the flow write to… | Deploy the flow in… |
|---|---|
| Only the HR Case (`sn_hr_core_case`), HR Task (`sn_hr_core_task`), or your own custom-scope tables | Custom app scope (`x_*`). SDK Fluent `Flow()` — Step 5b. |
| `sys_user`, `sys_user_has_role`, or other protected globals | `sn_hr_core` scope. MCP `create_flow` + Workflow Studio — Step 5c. |

This table is the *default*. The access check below **overrides** it: if the diagnosis shows the custom scope lacks a required operation on any target table (even an HR table on a locked-down instance), move the flow to `sn_hr_core` regardless of what the table suggests.

**Broaden the cross-scope diagnosis beyond just `sys_user`.** For *every* table the flow writes (not only `sys_user`), and for *every* operation (create/write/delete), run the sys_db_object check before generating code:

```
query_records('sys_db_object', 'name=<table>', 'name,read_access,create_access,write_access,delete_access')
```

If any required `<op>_access=false` on a target, privilege records will NOT unblock it — the flow must live in a trusted scope (`sn_hr_core` for HR writes). See hrsd-knowledge "Diagnosing Scope does not have access". For non-protected cross-scope targets, deploy `sys_scope_privilege` + `sys_restricted_caller_access` records (`source_scope`, NOT `principal_scope`) per hrsd-knowledge.

### 5b. Custom-scope flow (SDK `Flow()`)

Use this path only when the flow does NOT write protected globals. File: `src/fluent/flows/<service-name>-flow.now.ts`.

```typescript
import '@servicenow/sdk/global'
import { Flow, wfa, trigger, action } from '@servicenow/sdk/automation'
// Import the RP const ONLY if the flow reads RP variable values (e.g. getCatalogVariables).
// A flow with no RP (agent-created / manual-submitted service) must NOT import it.
// import { <RPConstName> } from '../catalog/<service-name>-rp.now'

Flow(
    {
        $id: Now.ID['<flow-id>'],
        name: '<HR Service Name> - Fulfillment',
        description: '<description>',
        runAs: 'system',
    },
    wfa.trigger(
        trigger.record.created,
        { $id: Now.ID['<trigger-id>'] },
        {
            table: '<COE case_table from Step 1>',   // must match the HR Service service_table, not necessarily sn_hr_core_case
            condition: 'hr_service=<HR Service sys_id from Step 2>',  // ✅ sys_id, NOT name. See hrsd-knowledge.
            run_flow_in: 'background',
        }
    ),
    _params => {
        // Actions are optional and service-specific. The createTask action below is ONE EXAMPLE,
        // not a required step — many flows just update the case or call other actions.
        wfa.action(
            action.core.createTask,
            { $id: Now.ID['create-hr-task'], annotation: 'Create HR Task linked to the HR Case' },
            {
                task_table: 'sn_hr_core_task',
                field_values: TemplateValue({   // createTask uses field_values; createRecord/updateRecord use values
                    parent: wfa.dataPill(_params.trigger.current, 'reference'),
                    // assigned_to: prefer an assignment GROUP or HR assignment rules.
                    // assigning to subject_person routes the work to the request subject (usually wrong) and
                    // can expose the task to that user — only do this if it's genuinely intended.
                }),
            }
        )
    }
)
```

- The trigger condition uses the **HR Service sys_id captured in Step 2**, never the name or a dot-walk (`hr_service=<sys_id>`). See hrsd-knowledge "Flow trigger condition".
- `TemplateValue` is a global — do NOT import it.
- Action signatures vary per action (`createTask`→`field_values`/`.task`; `createRecord`/`updateRecord`→`values`; `lookUpRecord`→`.Record`). See hrsd-knowledge "SDK action.core signatures".
- For RP variable values use `RP.variables.fieldName` (not string literals); add `// @ts-ignore TS4111` above dot-notation on OOB tables. See hrsd-knowledge.

### 5c. sn_hr_core-scope flow (protected-global writes)

Do NOT author via SDK — `Flow()` has no scope parameter and `sys_hub_flow` can't be deployed cross-scope from a custom project. Create the shell with MCP, author the body in Workflow Studio.

```
mcp__servicenow-mcp__create_flow(
    name: '<HR Service Name>',
    description: '<description>',
    scope: 'sn_hr_core',
    trigger_type: 'record',
    trigger_table: '<COE case_table from Step 1>',   // derive from topic_detail → COE, not hardcoded
)
```

Capture the returned sys_id. **Then set the trigger condition** — `create_flow` creates a shell with no filter condition, which would fire for every case on that COE table. After creation, open the flow in Workflow Studio and add the trigger condition `hr_service=<HR Service sys_id from Step 2>` (sys_id, not name — same rule as Step 5b). Verify in Workflow Studio that the trigger row displays "HR service is <Service Name>", not "HR service is (empty)". The action body (e.g., the standard 6-step onboarding pattern) MUST be authored in Workflow Studio — action input/output mappings are a compressed XML blob with no SDK/MCP API. See hrsd-knowledge "Standard 6-step onboarding flow pattern" for the body, including: look up an existing user before creating (idempotency — don't create duplicate `sys_user` records); do NOT manually create the HR Profile (auto-created on user insert); do NOT update `short_description` (already set by `createCaseFromProducer`); do NOT assign `new_hire` role unless Applicant Center is active.

**Update-set / transport note:** an `sn_hr_core` flow does NOT belong to your custom app's update set. Ensure it's captured in (or created under) the correct `sn_hr_core` application/update-set context so it transports to downstream instances — otherwise the HR Service will reference a flow sys_id that doesn't exist there. Document the deploy order: custom app first, sn_hr_core flow tracked separately.

### 5d. Flip the HR Service to flow fulfillment

Once the flow is built **and verified working**, update the Step 2 `Record()`:
- `fulfillment_type: 'flow'`
- `flow: '<flow sys_id>'` (accepts a sys_id from any scope, incl. sn_hr_core)

Redeploy and re-verify both fields. Keep these deploy notes in mind:
- `npm run deploy -- --reinstall` may be required on some PDIs ("Could not determine app installation status"). **Every `--reinstall` deactivates all flows in your custom scope** — they return to draft and must be re-activated (Step 8). Flows in sn_hr_core scope are unaffected.
- **`sys_translated_text`** records can be silently dropped from custom-scope deploys. After any deploy that includes them, `get_record('sys_translated_text', '<sys_id>')` each one and confirm `value`; re-add via System Localization > Translated Text if missing.

## Step 6: Employee Center publishing — *skip unless requestable in ESC*

Ask: **should this service be requestable in Employee Center?** If no (e.g., agent-created / agent-facing only), skip.

**Important:** An RP must be in the Human Resources Catalog to be submittable at all — even outside of ESC. If Step 3 built an RP and Step 6 is skipped, the RP will be linked to the HR Service via `producer` but not be submittable by anyone. The `catalogs` field below is the minimum required for any submittable RP; `categories` and the topic wiring are ESC-specific.

If yes, three associations make the RP appear in ESC (see hrsd-knowledge "ESC visibility"):
- **Catalog + Category**: set `catalogs: ['<hr_catalog sys_id>']` and `categories: ['<category sys_id>']` directly on the RP definition. Do NOT use standalone `Record()` for `sc_cat_item_catalog` / `sc_cat_item_category` — they create duplicates. Query `sc_category` filtered by `sc_catalog=<hr_catalog>` for the closest category (admin-manageable, not cached).
- **Topic**: a standalone `m2m_connected_content` `Record()` with `content_display_value` set explicitly (the deriving Business Rule does not fire on SDK installs, and ESC hides items where it's empty):

```typescript
Record({
    $id: Now.ID['<service>-esc-topic'],
    table: 'm2m_connected_content',
    data: {
        catalog_item: `${<RPConstName>}`,
        content_type: '<m2m_content_type from bootstrap>',
        topic: '<topic sys_id>',
        content_display_value: 'Catalog Item: <RP name>',
    },
})
```

Do NOT set `assignedTopics` on the RP — it generates a colliding `m2m_connected_content` row with empty `content_display_value`.

**Update-set note:** `m2m_connected_content` records and any user criteria records created via MCP are created directly on the instance — ensure your scoped update set is active before creating them so they are captured for transport to downstream instances.

**Populate `sc_cat_item.taxonomy_topic`:** on current releases ESC item discovery reads `sc_cat_item.taxonomy_topic` — the `m2m_connected_content` row alone is necessary but not sufficient. Set it explicitly rather than only verifying it: include `taxonomy_topic: '<topic sys_id>'` on the RP definition (or update the `sc_cat_item` record via MCP `update_record` after deploy if the SDK RP type doesn't expose the field). Then `get_record('m2m_connected_content', '<sys_id>')` to confirm non-empty `content_display_value`, and `get_record('sc_cat_item', '<RP sys_id>')` to confirm `taxonomy_topic` is set. If the item still doesn't surface in ESC, that field is the first thing to check.

**Record Producer user criteria (from Step 1):** if the audience is not "all employees", wire the RP's `Available For` / `Not Available For` user criteria here — this is the mechanism that gates employee visibility/submission in ESC, separate from the HR Service `hr_criteria`. Do not rely on `hr_criteria` alone to hide an ESC item.

## Step 6.5: German translations — always, after all English artifacts are deployed

All user-facing and agent-facing text must have a German translation. Implement this after the English content is complete and verified (not before), so translations don't need to be re-done if the English changes.

**What needs translating — collect the German equivalent for each:**

| Artifact | Fields to translate |
|---|---|
| HR Service | `name` — agent- and user-facing, and **embedded in the auto-generated case `short_description`** produced by `createCaseFromProducer`. If the HR Service name is not translated, German-language case submissions will have a mixed-language short description. |
| Record Producer | `name`, `short_description`, `description` |
| RP variables | `question` (label shown to the user) for each variable; choice `label` for each choice on SelectBox variables |
| HR Service template | `name` (if it has a user-visible name) |

**How to deploy translations via SDK `Record()`:**

Use `sys_translated_text` records. One record per field per language:

```typescript
import '@servicenow/sdk/global'
import { Record } from '@servicenow/sdk/core'
import { <RPConstName> } from './catalog/<service-name>-rp.now'

// HR Service name in German — also affects the auto-generated case short_description
Record({
    $id: Now.ID['<service>-i18n-service-name-de'],
    table: 'sys_translated_text',
    data: {
        tablename: 'sn_hr_core_service',
        fieldname: 'name',
        id: '<HR Service sys_id from Step 2>',
        language: 'de',
        value: '<German HR Service name>',
    },
})

// Example: RP name in German
Record({
    $id: Now.ID['<service>-i18n-rp-name-de'],
    table: 'sys_translated_text',
    data: {
        tablename: 'sc_cat_item',
        fieldname: 'name',
        id: `${<RPConstName>}`,
        language: 'de',
        value: '<German name>',
    },
})

// Example: RP short_description in German
Record({
    $id: Now.ID['<service>-i18n-rp-shortdesc-de'],
    table: 'sys_translated_text',
    data: {
        tablename: 'sc_cat_item',
        fieldname: 'short_description',
        id: `${<RPConstName>}`,
        language: 'de',
        value: '<German short description>',
    },
})

// Example: variable question label in German
// Variable labels live in sys_translated_text on the item_option_new table
Record({
    $id: Now.ID['<service>-i18n-var-employee-de'],
    table: 'sys_translated_text',
    data: {
        tablename: 'item_option_new',
        fieldname: 'question_text',
        id: '<variable sys_id>',   // query item_option_new by name + cat_item after RP deploy to get the sys_id
        language: 'de',
        value: '<German question label>',
    },
})
```

**`sys_translated_text` deploy caveat (from hrsd-knowledge):** these records can be silently dropped from custom-scope SDK deploys. After every deploy that includes translation records, `get_record('sys_translated_text', '<sys_id>')` each one and confirm `value` is populated. If a record is missing, re-add it via System Localization > Translated Text in the UI (or via the source record's i18n tab).

**Variable sys_ids:** the RP SDK `$id` gives you the catalog item sys_id, but variable labels are on `item_option_new` records. After the RP deploys, query `item_option_new` filtered by `cat_item=<RP sys_id>` and `name=<variable_name>` to get each variable's sys_id for the translation records.

**Collect all German strings up front** in a single question to the user before writing any translation records — gather every field listed in the table above at once rather than asking per-artifact.

## Step 7: ATF tests — always, scaled to what was built

Per global CLAUDE.md, every artifact needs ATF coverage in the same scoped app, named `Test - <Service Name>`, deployed with the artifacts and run via MCP (`run_atf_test` / `run_atf_suite`) under the self-healing loop. **Scale the assertions to what actually exists:**

- **Service-only**: HR Service exists, `active=true`, `service_table`, `topic_detail`, both `header_config_*`, `subject_person_access`, `badge` populated; `fulfillment_type` matches (`simple`).
- **+ Record Producer**: also assert the RP exists, `script` contains `createCaseFromProducer`, variable count ≥ expected, and the HR Service `producer` link is set.
- **+ Flow**: also assert `fulfillment_type=flow`, `flow` linked, flow `active=true` / `status=published`. Add a **positive submission test** (submitting the RP creates the HR case, fires the flow, produces expected downstream records).
- **Negative / authorization test**: add whenever the audience is **not "all employees"** (i.e. any restricted `hr_criteria` or RP user criteria), not only when a flow creates users — assert a user outside the criteria cannot see/submit the item. Add the stronger flow-denial assertion when the flow creates users or touches sensitive data.

Query by sys_id, not name. Run, read results, fix-redeploy-rerun until green per the self-healing loop.

## Step 8: Verify

Query each artifact that was built and report sys_id + key fields. Rows for artifacts you skipped don't apply.

| Artifact | Table | Built when | Must have |
|---|---|---|---|
| HR Service | `sn_hr_core_service` | always | `value`, `service_table=<COE case_table derived in Step 1>`, both `header_config_*`, `subject_person_access`, `badge`, `active=true`; `fulfillment_type` matches build; `hr_criteria` if specified |
| Record Producer | `sc_cat_item_producer` | Step 3 | `script` with `createCaseFromProducer`, variable count matches design; HR Service `producer` link set |
| Template | `sn_hr_core_template` | Step 4 | Record exists with correct `table=<COE case_table>` + `template` encoded query; HR Service `template` link populated |
| Flow (custom scope) | `sys_hub_flow` | Step 5b | `active=true`, `status=published`; trigger condition `hr_service=<sys_id>` resolves to the service name in Flow Designer |
| Flow (sn_hr_core) | `sys_hub_flow` filtered by `sys_scope=<sn_hr_core scope sys_id>` | Step 5c | `active=true`, `status=published`, body authored; trigger condition `hr_service=<sys_id>` set (displays as "HR service is <Name>" in Workflow Studio, not empty); HR Service `flow` references it |
| Catalog / Category | `sc_cat_item_catalog` / `sc_cat_item_category` | Step 6 | RP linked to HR Catalog + category |
| Topic | `m2m_connected_content` | Step 6 | `catalog_item` + `content_type` + `topic` set, non-empty `content_display_value`; `sc_cat_item.taxonomy_topic` populated |
| German translations | `sys_translated_text` | Step 6.5 | One record per translatable field per artifact (`language=de`, `value` non-empty); verify each individually via `get_record` — do not assume deploy succeeded |

**Activation ordering (avoid leaving the service inactive):** because `--reinstall` deactivates custom-scope flows, do the **final** `--reinstall` deploy *before* activating, then activate/re-activate last:
1. Deploy all artifacts (incl. ATF).
2. Re-activate any custom-scope flow that `--reinstall` dropped to draft — MCP `publish_flow(<sys_id>)` or Flow Designer **Activate**. (sn_hr_core flows authored in Workflow Studio end with **Save and Activate**.)
3. Run ATF and confirm green.

**Smoke test** (when an RP exists): submit the RP in Employee Center as a logged-in user and verify a new `sn_hr_core_case` with `hr_service=<your service sys_id>` and `short_description` set by `createCaseFromProducer`. Assert the **designed** opened-for / subject-person behavior, not a universal rule: for a self-service form `opened_for` = submitter; for an onboarding / "for someone else" form, `opened_for` and `subject_person` follow that design (e.g. `subject_person` = the newly created `sys_user`). If the flow writes `sys_user`: the new user exists, `subject_person` points to it, and its `sn_hr_core_profile` is populated.

Done when all built artifacts verify, ATF is green, and (if applicable) the smoke test produces all expected records.
