---
name: catalog-fulfillment-flows
description: Use when building, wiring, verifying, or debugging ServiceNow Flow Designer fulfillment flows for Service Catalog items — the sc_req_item trigger pattern, approval-subflow steps, catalog task creation, variable pills, Fluent authoring patterns, draft-flow wiring verification, and flow testing. Companion to catalog-item-builder (the item side); invoke for any catalog flow work including "the flow runs but does nothing", "pills are empty", or "approval never fires".
---

# Catalog Fulfillment Flows — build, wire, verify

**The rule that pays for everything else: build success ≠ correct.** A flow can import, publish,
and even execute while its condition literals were stripped, its subflow inputs never bound, or
its pills resolve to nothing. **Every flow gets a wiring verification after creation** — no
exceptions, no "it compiled".

API shapes (Fluent syntax, action schemas) come from `npx @servicenow/sdk explain <topic>` and
the live instance — this skill carries only what those sources don't: field-tested patterns and
hazards. Trap references (T-numbers) point to `catalog-item-builder/references/traps.md`.

## Standard shape

- Flow record: `type=flow`, `run_as=system` (unless the design needs user context),
  `status=published`, global/engagement scope per the locked decisions.
- **Trigger: Service Catalog → Requested Item (`sc_req_item`)** — fires on submit. Per-item
  targeting is via which flow the item's `flow_designer_flow` field points to, **not** a trigger
  condition.
- **Approval is a step inside the flow**: call the engagement's reusable approval subflow early,
  gate fulfillment on `approval == approved`, handle rejected explicitly.
- Fulfillment tasks → OOB **Create Catalog Task** action; stages updated as the flow progresses.
- Multi-item shared flows: one branch per item (each with its own task template + group);
  approval first; per-branch create-vs-retire semantics per the spec.

## Wiring patterns (each one failed silently before it was learned)

**Pills.** The catalog trigger's record pill is `{{Service Catalog_1.request_item}}` — note the
`_1` instance suffix. The un-suffixed form looks right and resolves to nothing.

**Create Catalog Task (OOB action, same sys_id on all instances:
`af51fd0e73141300612c273ffff6a785`).** Inputs: `ah_table_name=sc_task`,
`ah_requested_item={{Service Catalog_1.request_item}}`, `ah_short_description=<title>`,
`ah_fields=assignment_group={"display":"<name>","value":"<sys_id>"}^description=...`
(`^`-delimited encoded), `ah_wait=1` to pause until the task completes.

**Approval subflows.** The input is the **RITM record** even when the input's label suggests
otherwise (a label like `cat_item` misleads). Output is an approval choice value. Call the
subflow via **typed import / logical name** — a sys_id-string fallback appears to work but the
inputs never bind at runtime.

**Assignment groups — resolve by indirection, never hardcode.** Two-step pattern: Look Up
`sys_properties` by name (`<prefix>.assignment_group.<Name>`) → Look Up `sys_user_group` by the
property's *value*. Transport-safe across instances. And **check the property VALUE exists** —
an empty scaffold property routes every task to nothing (see `catalog-item-builder` Phase 2).

**Approval by CI owner with fallback.** ONE "Set Flow Variables" step whose value script returns
the CI's `managed_by_group` or the fallback group (top-level `return` required in flow value
scripts), then ONE approval step on the variable. Duplicated approval branches drift.

**Fire Event.** `parm1`/`parm2` must be **String** data pills (e.g. `…▸Sys ID`), never a
reference pill — a reference pill throws a runtime GlideRecord-proxy cast error. Register the
event in the Event Registry and create the consuming notification; an unregistered event fires
into the void.

**Date-age branching** ("within/older than N years"): a relative encoded query in a Look Up
Record — e.g. `purchase_dateRELATIVEGT@year@ago@5`. Dynamic, transport-safe, no scheduled job
or property needed.

**MRVS rows at fulfillment** live in `sc_multi_row_question_answer` with `parent_id` (RITM),
`variable_set`, `item_option_new` (column), `row_index`.

**Stage ordering:** set the terminal stage (Request Completed / Cancelled) AFTER the final
record update, before any log step — otherwise the stage lies while work is still running.

**Annotations:** builder-facing → author them in the builders' working language (typically
English) regardless of the end-user language architecture.

## Fluent authoring specifics (config-path / SDK-generated flows)

- Condition literals: write `=value` **without spaces**; spaced forms get stripped.
- **Look Up Record conditions can silently lose literal values** on import — verify every
  lookUpRecord's conditions on the instance afterward (this is the canonical "flow runs but
  finds nothing" cause).
- Subflow inputs by logical name; `TemplateValue` for field templates.
- **NEVER `now-sdk transform` an instance-owned flow/subflow** — it creates a stub that deploys
  and OVERWRITES the real artifact (T18). Inspect `dist/` before every deploy (T19 guard).

## Verification (mandatory, per flow)

1. **Config-path/update-set–imported draft flows have an EMPTY `sys_hub_action_instance`** —
   querying it proves nothing. Verify wiring by decompressing the flow snapshot payload
   (`sys_hub_flow` → latest snapshot → base64/gzip JSON) and checking each action's bound
   inputs, or by opening the flow in the UI.
2. Check per flow: trigger table + type; every condition's literals survived; every subflow
   call's inputs bound; every pill resolves (no blank `ah_requested_item`); approval gate wired
   to the output value actually produced; task fields encoded correctly; stages in order.
3. Confirm `sc_cat_item.flow_designer_flow` points at THIS flow:
   `get_record sc_cat_item <id>` after linking.
4. Reference-variable prerequisite: `setTableName - empty table name` in Get Catalog Variables
   means a type-8 variable has a blank reference table — fix the variable, not the flow (T3).

## Testing

**Do not trust the Flow Designer "Test" button for catalog flows.** It runs with an empty
`source_record`, so every catalog-variable pill comes back blank — the flow "fails" with no
data, and the failure is not a bug (a real two-day debugging loss). **Test by submitting the
actual catalog item** (`order_catalog_item` or the portal) with representative variable values,
then inspect the flow execution context (`get_flow_execution` / operation view) for each step's
real inputs/outputs.

Post-test sweep per item: RITM created; approval created for the right approver; tasks created
with the right group, template, and language; stages progressed; CMDB/record side-effects match
the spec; rejected path behaves.
