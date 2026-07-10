# Catalog build traps — hazard log with verification commands

Every entry was learned on a live engagement, **outside** the SDK docs. Format: symptom → cause
→ rule → **verify** (the cheap command that proves the state). Verify commands use the ServiceNow
MCP `query_records`/`get_record` tools or `now-sdk`; adapt table/field syntax as needed.
Sys_ids quoted here are **OOB records** (identical across instances) unless marked otherwise.

## Variables & sets

**T1 — Variable type codes are not what you assume.**
Symptom: a "Yes/No" variable renders as something else entirely.
Cause: `item_option_new.type` is numeric; e.g. **1 = Yes/No** (not text), 6 = single-line text,
8 = reference, 19/20 = container start/end.
Rule: never write a type code from memory.
Verify: `query_records sys_choice name=item_option_new^element=type` — or read one known-good
variable of the intended kind and copy its code.

**T2 — `io_set_item` insert silently blocked by name collision.**
Symptom: the set↔item link record just doesn't appear; no error surfaced.
Cause: OOB business rule "Check for same name variables" aborts the insert when two attached
sets share a variable internal name (e.g. both have `requested_for`).
Rule: insert via GlideRecord with `setWorkflow(false)` — then see T14 (capture!). Better: detect
the collision beforehand and take it to the human gate (it may be a real spec conflict).
Verify: `query_records io_set_item sc_cat_item=<item>^variable_set=<set>` — row exists with
the intended `order`.

**T3 — Reference variable with a blank reference table.**
Symptom: flows later fail with `setTableName - empty table name` in Get Catalog Variables.
Cause: a type-8 variable whose `reference` (target table) is empty. The UI picker stores the
table *name*, not label.
Rule: reference table is mandatory in the spec; fix the variable, not the flow.
Verify: `query_records item_option_new type=8^referenceISEMPTY^variable_set=<set>` — expect 0.

**T4 — MRVS columns can't see parent-form variables via UI policy.**
Symptom: a multi-row set column that should react to an outer variable never does.
Cause: MRVS policies are scoped to the MRVS's own columns.
Rule: parent-driven column behavior needs a catalog client script on the set using
`g_service_catalog.parent`; own-column rules can stay UI policy.
Verify: functional — open the item, change the parent variable, watch the column.

**T5 — Loose item variables vs the set policy.**
If the engagement standard is "all variables in sets", a loose variable is a defect even though
the platform allows it.
Verify: `query_records item_option_new cat_item=<item>^variable_setISEMPTY` — expect 0.

## Choices & pricing

**T6 — Choice prices don't go in `price`.**
Symptom: per-choice surcharges silently vanish.
Cause: `question_choice` surcharges live in **`misc`** (one-time) and **`rec_misc`** (recurring);
writes to `price`/`recurring_price` are dropped. Checkbox variables differ: they keep
`price_if_checked`/`rec_price_if_checked` on the variable.
Verify: `query_records question_choice question=<var>` — check `misc`/`rec_misc` values.

## Item record

**T7 — Import-set/transform creation drops and auto-fills fields.**
Symptom: `taxonomy_topic` empty after create; `delivery_plan`/`owner`/`ignore_price` populated
with values you never sent.
Cause: any import-set path only maps what the transform maps; the platform then auto-fills
defaults on insert.
Rule: after creating `sc_cat_item` through any indirect path, explicitly patch and verify every
spec field. Prefer direct Table API for the item record.
Verify: `get_record sc_cat_item <sys_id>` — diff every spec field, especially `taxonomy_topic`,
`category`, `sc_catalogs`, `flow_designer_flow`, pricing, `access_type`.

**T8 — Placement is per-item data, never a default.**
Catalog, category, taxonomy topic are read from the spec for THIS item. Copying a sibling's
placement is a defect even when it happens to look right.
Verify: same query as T7, against the spec's `placement:` block.

## UI policies & client scripts

**T9 — "UI policy actions can't be built programmatically" is a MYTH — but one path does break.**
Truth: SDK `CatalogUiPolicy` (with `actions[]` / `variableName`) and direct Table API both work.
Only the import-set path silently drops the `ui_policy`/`catalog_variable` bindings.
Storage facts: the condition lives in **`catalog_conditions`** as `IO:<variable_sys_id>` tokens
(not a plain encoded query of names); action `catalog_variable` stores `IO:<sys_id>`;
`visible`/`mandatory`/`disabled` are **3-state**: `true`/`false`/`ignore`.
Verify: `query_records catalog_ui_policy_action ui_policy=<policy>` — every row's
`catalog_variable` = `IO:<sysid>` of the right variable. API shape: `npx @servicenow/sdk explain
cataloguipolicy-api`.

**T10 — Catalog client script field gotchas.**
`type` must be the **string** `"onChange"` (etc.); the triggering-variable field is
**`cat_variable`** (not `variable_name`); `ui_type` 10 = All. SDK `CatalogClientScript`
`appliesTo: 'set'` for set-level scripts.
Verify: `query_records catalog_script_client <sys_id>` — check `type`, `cat_variable`, `ui_type`.

**T11 — OOB-first is a hard rule, not taste.**
Show/hide/mandatory/read-only → UI policy. Client script ONLY for data computation or
pre-population. If a requirement seems to need a scripted workaround for something policies
normally do — stop and ask; there is usually an OOB way or a spec misreading.

**T12 — Live-computed field pattern (dynamic totals/pricing).**
Read-only text variable + Script Include (client-callable, GlideAjax) + a set-level onChange
client script per input, each recomputing the FULL total (order-independent). There is no
headless way to flip a variable's type — type changes are UI-only; design the type right first.

## Translations

**T13 — Translated content does NOT transport in update sets.**
Symptom: target instance shows English only; update set previewed clean.
Cause: `sys_translated_text` rows (per-record: descriptions, help texts) and `sys_translated`
(per-value: labels/titles) are not update-set tracked.
Rule: translations are a **separate XML export deliverable**, built and refreshed per batch.
Which mechanism: `sys_translated_text` for text/html fields; `sys_translated` for
translated_field labels. Author primary language first; translate as a distinct later step.
Verify: `query_records sys_update_xml update_set=<set>^nameLIKEsys_translated` — expect ABSENT;
then `query_records sys_translated_text tablename=<t>^documentkey=<sys_id>` — rows exist.

## Transport & update sets

**T14 — `setWorkflow(false)` skips update-set capture.**
Anything inserted that way is invisible to the transport. Force-touch afterwards (a normal
`update()` on a real field) so the record is captured.
Verify: `query_records sys_update_xml update_set=<set>^target_name=<record>` — row exists.

**T15 — Scheduled-job traps (when using jobs as a create/patch vehicle).**
Display-name reference resolution on insert; `active=false` jobs never fire; delete temp jobs
before export or they ship to the customer.
Verify: `query_records sysauto_script nameLIKE<your-prefix>` — expect 0 before export.

**T16 — Verify capture after every build step, not at the end.**
The single query `query_records sys_update_xml update_set=<active>^ORDERBYDESCsys_updated_on`
after each step catches capture gaps while the fix is still one record, not an archaeology dig.

## SDK layer

**T17 — The SDK can deploy to true Global scope.**
`now.config.json`: `scopeId: "global"` + `packageResolverVersion: "2.0.0"` — no custom app
needed. (Corrects the widespread "SDK = scoped apps only" belief.)
Verify: after deploy, `query_records <artifact table> sys_scope.scope=global^name=<artifact>`.

**T18 — NEVER `now-sdk transform` an instance-owned flow/subflow.**
Transform writes a stub under `src/fluent/generated/` that **deploys and overwrites the real
instance artifact** (a live merged approval subflow was wiped this way). Call instance-owned
subflows by reference; never pull them into the package.
Verify before EVERY deploy: inspect `dist/` for update records targeting artifacts you did not
author this session — any unexpected `sys_hub_flow`/`sys_hub_sub_flow` entry is an abort.

**T19 — Config-path deploys can DELETE instance artifacts.**
A `keys.ts`/metadata entry with `deleted: true` becomes a DELETE on the instance
(`author_elective_update`). One stale key can remove a production flow.
Rule: run a guard script (`npm run guard`) that greps the build output for delete markers and
unexpected targets, wired as a pre-deploy gate. Guards are code, not vigilance.
Verify: guard passes + T18 inspection of `dist/`.

**T20 — SDK can't resolve catalog variables of items it didn't create.**
Symptom: `getCatalogVariables`/variable pickers come up empty for items created via Table API.
Rule: reference the variables explicitly (hardcoded `sys_id:item_option_new` list) instead of
relying on SDK resolution.
Verify: open the generated flow in the UI and confirm the variable list is populated.
