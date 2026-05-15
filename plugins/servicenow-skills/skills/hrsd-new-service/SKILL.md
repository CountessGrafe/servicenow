---
name: hrsd-new-service
description: Create a complete HRSD service on ServiceNow — Record Producer, fulfillment flow, HR Service, and Employee Center wiring. Requires now-sdk + Fluent. MCP is used where available. Custom table creation is out of scope — use a separate skill for that.
---

Read @hrsd-knowledge/SKILL.md before proceeding — it contains all HRSD platform patterns referenced below.

## Step 1: Gather service definition

Ask the user for everything needed before writing any code. Collect in a single conversation turn where possible:

**Required:**
- Service name (e.g., "Office Plant Request")
- Scope prefix of the scoped app (e.g., `x_solv_plants`)
- Record Producer variables: for each variable, get label, name, type (SingleLineText, SelectBox, Reference, MultiLineText), mandatory flag, read-only flag, default value if any, and choices if SelectBox type

**Optional — offer to skip:**
- HR Service template (sys_id)
- HR Service case_options (sys_id)
- HR Service hr_criteria (sys_id)
- HR Service fulfillment_instructions (plain text)
- HR Service case_creation_service_config (sys_id)

Derive automatically (do not ask):
- `hr_service_value`: snake_case of service name — e.g., `office_plant_request`

## Step 2: Pre-flight checks

**2a. Confirm the target instance.** Ask which ServiceNow instance this is for if not already clear. All MCP operations target that instance.

**2b. Ensure an update set is active** that matches the scoped app. Query the current active update set via MCP (`get_current_update_set`). If it is "Default" or belongs to a different scope, create a new update set named after the service (e.g., `SnackRequest - Office Snack Request`) and switch to it before continuing.

**2c. Confirm the SDK project exists** at the expected path. If it doesn't exist, run:
```bash
npx @servicenow/sdk init --appName "<ServiceName>" --scopeName "<scope_prefix>" --template base
npm install
npm run types
```

**2d. Look up OOB reference values from the instance** — never hardcode these:
- `header_config_opened_for` and `header_config_subject_person`: query any active `sn_hr_core_service` record that has them populated
- `content_type` for ESC topic assignment: query any `m2m_connected_content` record that has `catalog_item` populated
- Human Resources Catalog sys_id: query `sc_catalog` where title contains "Human Resources"
- Appropriate topic sys_id: query `topic` table, choose the best match for the service subject matter
- Appropriate category sys_id: query `sc_category` table, choose the best match
- General topic detail sys_id: query `sn_hr_core_topic_detail` where name="General"

## Step 3: Write SDK source files

Create two files. Custom table creation is out of scope for this skill — if a table is needed (e.g., for integration data from Sage, SuccessFactors, Softgarden, etc.), handle it separately before running this skill.

**3a. Record Producer** — `src/fluent/catalog/<service-name>-rp.now.ts`

```typescript
import '@servicenow/sdk/global'
import {
    CatalogItemRecordProducer,
    ReferenceVariable,
    SingleLineTextVariable,
    SelectBoxVariable,
    MultiLineTextVariable,
} from '@servicenow/sdk/core'

export const <RPConstName> = CatalogItemRecordProducer({
    $id: Now.ID['<rp-id>'],
    name: '<RP Name>',
    table: 'sn_hr_core_case',
    shortDescription: '<short description>',
    description: '<description>',
    script: 'new sn_hr_core.hr_ServicesUtil(current, gs).createCaseFromProducer(producer, cat_item.sys_id);',
    variables: {
        employee: ReferenceVariable({
            question: 'Employee',
            referenceTable: 'sys_user',
            order: 1,
            readOnly: true,
            defaultValue: 'javascript:gs.getUserID()',
        }),
        // add remaining variables from user's definition
    },
})
```

Rules:
- The `script` field is mandatory — omitting it means no HR Case is created on submission
- Export as a named const — the flow imports it
- `employee` pre-filled with `gs.getUserID()` is standard — always include it
- Do NOT set both `readOnly: true` and `mandatory: true` on the same variable
- For SelectBoxVariable: `{ value: { label: 'Label', sequence: N, inactive: false } }`

**3b. Fulfillment flow** — `src/fluent/flows/<service-name>-flow.now.ts`

```typescript
import '@servicenow/sdk/global'
import { Flow, wfa, trigger, action } from '@servicenow/sdk/automation'

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
            table: 'sn_hr_core_case',
            condition: 'hr_service.name=<HR Service Name>',
            run_flow_in: 'background',
        }
    ),
    _params => {
        wfa.action(
            action.core.createTask,
            { $id: Now.ID['create-hr-task'], annotation: 'Create HR Task linked to the HR Case, assigned to the subject person' },
            {
                task_table: 'sn_hr_core_task',
                field_values: TemplateValue({
                    parent: wfa.dataPill(_params.trigger.current, 'reference'),
                    // @ts-ignore TS4111: SDK requires dot notation; short_description is valid on sn_hr_core_case
                    short_description: wfa.dataPill(_params.trigger.current.short_description, 'string'),
                    // @ts-ignore TS4111: SDK requires dot notation; subject_person is valid on sn_hr_core_case
                    assigned_to: wfa.dataPill(_params.trigger.current.subject_person, 'reference'),
                }),
            }
        )
    }
)
```

Rules:
- The RP import is not needed in the flow unless RP variable values must be used in a flow step (e.g., passing data to an integration). Add `getCatalogVariables` only when required.
- `TemplateValue` is a global — do NOT import it
- Add `// @ts-ignore TS4111` above any dot-notation access on OOB tables without Fluent type definitions

## Step 4: Deploy

```bash
npm run deploy -- --reinstall
```

After deploy, query the instance via MCP to get sys_ids:
- `sc_cat_item_producer` by name → RP sys_id
- `sys_hub_flow` by name → flow sys_id

## Step 5: Create HR Service via MCP

Create a new `sn_hr_core_service` record with ALL fields in a single create call:

```
name:                         <Service Name>
value:                        <hr_service_value>
service_table:                sn_hr_core_case
topic_detail:                 <General topic detail sys_id from Step 2d>
fulfillment_type:             simple
producer:                     <RP sys_id from Step 4>
flow:                         <Flow sys_id from Step 4>
header_config_opened_for:     <from Step 2d>
header_config_subject_person: <from Step 2d>
subject_person_access:        true
active:                       true
```

Include any optional fields the user provided in the same create call.

`service_table` is silently ignored on updates — it MUST be in the create call. After creating, query the record back and verify `service_table`, `producer`, and `flow` are all populated. If any are missing, delete and recreate — do not attempt to fix via update.

## Step 6: Activate the flow in Flow Designer

Tell the user:

> The flow is deployed but in draft state — its trigger is not registered until you activate it in Flow Designer. This cannot be done via API.
> 1. Open Flow Designer on the instance
> 2. Search for "<Flow Name>"
> 3. Click **Activate**
>
> Come back once it's active.

Wait for confirmation before continuing.

## Step 7: Wire up Employee Service Center

Create three records via MCP:

**Catalog** (`sc_cat_item_catalog`):
```
sc_catalog: <HR Catalog sys_id from Step 2d>
sc_cat_item: <RP sys_id from Step 4>
```

**Category** (`sc_cat_item_category`):
```
sc_category: <category sys_id from Step 2d>
sc_cat_item: <RP sys_id from Step 4>
```

**Topic** (`m2m_connected_content`):
```
catalog_item: <RP sys_id from Step 4>
content_type: <content_type sys_id from Step 2d>
topic: <topic sys_id from Step 2d>
```

After creating the topic record, query it back and confirm `content_display_value` shows "Catalog Item: <RP Name>". Empty means `catalog_item` or `content_type` is wrong.

## Step 8: Verify

Query every artifact and report sys_id + key fields:

| Artifact | Table | Must have |
|---|---|---|
| HR Service | `sn_hr_core_service` | `value`, `service_table`, `producer`, `flow`, `header_config_opened_for`, `header_config_subject_person`, `subject_person_access=true` |
| Record Producer | `sc_cat_item_producer` | `script` populated, variable count matches |
| Flow | `sys_hub_flow` | `active=true`, `status=published` |
| Catalog | `sc_cat_item_catalog` | RP linked to HR catalog |
| Category | `sc_cat_item_category` | RP linked to chosen category |
| Topic | `m2m_connected_content` | `content_display_value` populated |

Done when all checks pass.
