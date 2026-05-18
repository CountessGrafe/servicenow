---
name: hrsd-knowledge
description: HRSD platform knowledge reference for ServiceNow — patterns, constraints, and pitfalls for HR Service, Record Producer, and Flow Designer. Import with @ in other skills.
---

## Record Producer script (mandatory)

Every HR Record Producer MUST have this in the Script field:

```javascript
new sn_hr_core.hr_ServicesUtil(current, gs).createCaseFromProducer(producer, cat_item.sys_id);
```

Without it, an HR Case is still created on submit, but it will be missing `subject_person`, `opened_for`, and a properly formatted `short_description`. The case is incomplete and will not behave correctly in the HRSD lifecycle. This call populates those fields correctly. It must be passed as a plain string — not a typed function — to avoid `cat_item` parameter type conflicts in the SDK.

## Flow trigger

HR fulfillment flows trigger on `sn_hr_core_case` record creation, NOT on a catalog trigger. The catalog trigger fires for standard catalog items only — Record Producers in HRSD bypass `sc_req_item` entirely.

```typescript
wfa.trigger(
    trigger.record.created,
    { $id: Now.ID['<trigger-id>'] },
    {
        table: 'sn_hr_core_case',
        condition: 'hr_service=<HR Service Name>',
        run_flow_in: 'background',
    }
)
```

## getCatalogVariables in HRSD

Record Producers do NOT create `sc_req_item`. In HRSD, the HR Case itself is the submitted request. Use the HR Case as `requested_item`:

```typescript
import { MyRP } from '../catalog/my-rp.now'

const catalogVars = wfa.action(
    action.core.getCatalogVariables,
    { $id: Now.ID['get-catalog-vars'], annotation: '...' },
    {
        requested_item: wfa.dataPill(_params.trigger.current, 'reference'),
        template_catalog_item: `${MyRP}`,
        catalog_variables: [
            MyRP.variables.field_one,
            MyRP.variables.field_two,
        ],
    }
)
```

**Critical**: import the RP and use `RP.variables.fieldName` — not string literals. The SDK uses these imports to infer output data pill types. Using strings causes "Unknown instance type" errors at transform time.

`TemplateValue` is a global — do NOT import it.

## TypeScript TS4111 vs TS212 conflict

OOB tables (e.g., `sn_hr_core_case`) without Fluent type definitions resolve to `Record<string, unknown>`. TypeScript requires bracket notation (TS4111) but the SDK transformer requires dot notation (TS212). Fix with `// @ts-ignore TS4111` above the affected line:

```typescript
// @ts-ignore TS4111: SDK requires dot notation; subject_person is valid on sn_hr_core_case
u_employee: wfa.dataPill(_params.trigger.current.subject_person, 'reference'),
```

## SDK variable constraint: readOnly + mandatory

SDK `ReferenceVariable` (and other variable types) cannot have both `readOnly: true` and `mandatory: true`. If a field is read-only and auto-filled (e.g., Employee pre-filled from `gs.getUserID()`), set `readOnly: true` only — the field is effectively mandatory without the flag.

## HR Service: all required fields

When creating `sn_hr_core_service`, ALL of these must be set at creation time:

| Field | Notes |
|---|---|
| `name` | Display name of the service |
| `value` | Snake_case key, e.g., `office_snack_request` |
| `service_table` | Must be `sn_hr_core_case` for standard HRSD. **Set at creation — update via API is silently ignored.** |
| `topic_detail` | sys_id of the topic detail record (determines COE implicitly via `topic_detail.topic_category.coe`) |
| `fulfillment_type` | `simple` for standard manual fulfillment |
| `producer` | sys_id of the Record Producer (after deploy) |
| `flow` | sys_id of the Flow (after deploy) |
| `header_config_opened_for` | sys_id from existing HR service — always the same OOB value across all services |
| `header_config_subject_person` | sys_id from existing HR service — always the same OOB value |
| `subject_person_access` | `true` so employees can see their own case |
| `badge` | Set to `HR` — not required for the service to appear in Employee Center, but recommended for correct styling and categorisation |
| `active` | `true` |

Optional fields to ask about: `template`, `case_options`, `hr_criteria`, `fulfillment_instructions`, `case_creation_service_config`.

Look up `header_config_opened_for` and `header_config_subject_person` from an existing active HR service rather than hardcoding:

```
query sn_hr_core_service where active=true, return header_config_opened_for, header_config_subject_person
```

## COE is implicit — never set it directly

COE on the HR Service is derived automatically: `topic_detail → topic_category → coe`. Choose a `topic_detail` whose `topic_category.coe` is `sn_hr_core_case` for a standard HR case service. The "General" topic detail (look it up by name on the instance) covers the common case.

## Flow not triggering after deploy

Two separate things must be true for the flow to fire — check both:

**1. Flow must be active**
The SDK may deploy flows in draft state. Open Flow Designer, find the flow, and confirm it is active. If not, click **Activate**. This cannot be done via MCP or the Table API.

**2. Trigger condition must match the HR Service name exactly**
This is the more common failure. The condition `hr_service=<Service Name>` is a reference field condition — the value must be the HR Service's `name` field verbatim. A wrong name, extra space, or using `hr_service.name=` instead of `hr_service=` will silently prevent the flow from triggering even when the flow is active and the case is created.

```typescript
// ✅ Correct
condition: 'hr_service=Office Plant Request'

// ❌ Wrong — dot notation does not work on reference conditions
condition: 'hr_service.name=Office Plant Request'
```

Always verify by querying the HR Service record and copying the `name` field value directly rather than typing it.

## Restricted caller access after cross-scope deploy

When a flow deployed in a scoped app (e.g., `x_solv_plants`) creates records in an OOB scope (e.g., `sn_hr_core`), ServiceNow automatically creates a `sys_scope_privilege` record with `status=requested`. The flow will fail at runtime until this is approved.

After every deploy, query `sys_scope_privilege` for requested records and update them to `allowed`:

```
query sys_scope_privilege where status=requested, principal_scope=<your app scope sys_id>
→ update each record: status = allowed
```

Do this via MCP immediately after verifying the deploy, before instructing the user to activate the flow.

## ESC visibility: catalog, category, topic

Three separate records are required for the Record Producer to appear in Employee Service Center:

**1. Catalog assignment** (`sc_cat_item_catalog`):
```
sc_catalog: <Human Resources Catalog sys_id>
sc_cat_item: <RP sys_id>
```

**2. Category assignment** (`sc_cat_item_category`):
```
sc_category: <appropriate category sys_id>
sc_cat_item: <RP sys_id>
```

**3. Topic assignment** (`m2m_connected_content`) — use these exact fields:
```
catalog_item: <RP sys_id>
content_type: <look up from existing m2m_connected_content record>
topic: <topic sys_id>
```

The `content_type` field references `taxonomy_content_configuration`. Do NOT use a generic `content` field — it won't populate `content_display_value` and the RP won't surface in ESC. Look it up from any existing `m2m_connected_content` record that has a `catalog_item` set.
