---
name: catalog-item-builder
description: Use when building or bulk-building ServiceNow Service Catalog items (item records, variable sets, variables, choices, catalog UI policies, catalog client scripts, translations) on any instance — from a structured spec, at any scale from one item to a full migration. Owns the 6-phase delivery pipeline (bootstrap → spec → resolve → build → verify → record), the artifact-routing map (SDK vs Table API vs never-import-set), the ordered build recipe with per-step verification, and the platform trap checklist. Companion to catalog-spec-authoring (produces the input) and catalog-fulfillment-flows (the fulfillment side).
---

# Catalog Item Builder — spec → verified items, at scale

**Working principle: replace LLM prose with machine-verifiable structure at every phase.**
Extract specs with a script, build from the spec, verify with a diff, and spend model judgment
only in the gaps between. This is what makes bulk builds simultaneously *correct* and *cheap* —
a proven zero-defect rate on 18-item batches came from the verify-diff, not from care.

Platform behavior claims in this skill follow an admission rule: everything here was learned
**outside** the SDK docs and ships with its **own verification command**. For API shapes
(what a `CatalogUiPolicy` accepts, Fluent syntax), the authority is `npx @servicenow/sdk explain
<topic>` and the live instance — never this file, never memory. When this file and the instance
disagree, the instance wins; report the discrepancy.

## The pipeline

| Phase | Owner | Output |
|---|---|---|
| 0 Bootstrap (once/engagement) | this skill | conventions doc, locked decisions, pilot item, guards |
| 1 Spec (per item, scripted) | `catalog-spec-authoring` | `specs/<ID>.yaml`, TBDs signed off |
| 2 Resolve | this skill | every `TO_RESOLVE` → verified sys_id |
| 3 Build (batched) | this skill (+ `catalog-fulfillment-flows`) | artifacts on instance, in the transport container |
| 4 Verify | `catalog-verifier` agent | GREEN / DEFECTS / BLOCKED + diff report |
| 5 Record | this skill | build-state update, batch report, new traps saved |

## Phase 0 — Engagement bootstrap (once)

1. **Confirm instance + transport before creating anything**: `get_current_instance`, and the
   transport container (update set / scoped app / source control). If update sets: confirm the
   active one (`get_current_update_set`); creating containers is typically the user's call — ask.
2. **Reverse-engineer a conventions doc** from 1–2 reference items the client considers "right":
   query the actual records (item fields, set structure, attachment orders, flow shape, naming)
   and write `docs/conventions.md` — the build bible. New items must be indistinguishable from
   the reference. Include a reusable-components table (sets, subflows, groups) as *named sys_id
   handles*, and mark them as lookups, not defaults.
3. **Lock the decisions** (in the project CLAUDE.md or conventions doc): scope; variable-set
   policy (e.g. "all variables in sets, never loose"); flow trigger pattern; approval pattern
   map; language architecture; placement rule ("catalog/category/taxonomy always per item from
   the source").
4. **Build ONE pilot item end-to-end** before batching. Every platform trap it exposes goes into
   the trap log with its verification command. Batching before the pilot multiplies defects by
   batch size.
5. **Install guards as code, not vigilance**: a pre-deploy script that blocks known-catastrophic
   states (see traps T17–T19), wired as `npm run guard` or a hook.

## Phase 2 — Resolve (names → sys_ids, context-first)

For every `TO_RESOLVE` in the spec batch, query the instance and write a `_resolved.yaml`
(name → sys_id → evidence query). Rules:
- **Query before create. Reuse before build.** Search for an equivalent existing artifact
  (same type, active scope) before creating one; attach existing sets by sys_id when they
  genuinely fit.
- **Never assert data is missing from notes/memory — query.** TBD notes and prior sessions go
  stale; `query_records` is the only ground truth.
- **Check property/config VALUES, not existence.** A scaffolded-but-empty system property or
  group resolves lookups to nothing at runtime (real incident: an entire `assignment_group.*`
  property family existed but was blank — every flow routed nowhere).
- Anything unresolvable → back to the human gate as a TBD; never substitute a plausible record.

## Phase 3 — Build (batched, ordered, verified per step)

Batch items with the same shape (9–18 worked well); the recipe context amortizes across the batch.

**Choose the creation path per artifact — this routing was expensive to learn:**

| Artifact | Preferred path | Avoid | Why (trap ref) |
|---|---|---|---|
| Variable set (`item_option_new_set`) | Table API create | — | |
| Variables (`item_option_new`) | Table API create | guessing type codes | T1 |
| Choices (`question_choice`) | Table API create | `price` columns | T6 |
| Item (`sc_cat_item`) | Table API create | import-set/transform path | T7 |
| Set↔item link (`io_set_item`) | GlideRecord w/ `setWorkflow(false)` + force-touch | plain insert when name collision | T2, T14 |
| Catalog UI policy + actions | SDK `CatalogUiPolicy` (or Table API) | import-set path (drops bindings) | T9 |
| Catalog client scripts | SDK `CatalogClientScript` (or Table API) | wrong `type`/binding fields | T10 |
| Translations | `sys_translated_text` / `sys_translated` rows | assuming update-set capture | T13 |
| Fulfillment flow | see `catalog-fulfillment-flows` | `now-sdk transform` of instance flows | T18 |

**Build order per item** (each step ends with its verification query — all in
`references/traps.md`):

1. Variable set record → verify by sys_id.
2. Variables into the set → verify count + types + reference tables (T1, T3).
3. Choices → verify labels AND price columns (T6).
4. Item record → verify all spec fields **including** `taxonomy_topic` and placement (T7);
   fields silently auto-filled by the platform get explicitly re-set.
5. `io_set_item` attachments with spec order → verify rows + update-set capture (T2, T14).
6. UI policies + actions (OOB-first: policies for show/hide/mandatory/read-only; client
   scripts ONLY for computation/pre-population — if unsure which, stop and ask) → verify
   `catalog_conditions` tokens and action bindings (T9).
7. Client scripts where genuinely needed → verify type + `cat_variable` binding (T10–T12).
8. Translations for every translated field/record → verify rows exist AND plan the separate
   export (T13).
9. Flow (companion skill) → link via `sc_cat_item.flow_designer_flow` (not `workflow`).

**Script the mechanical bulk.** Generation scripts (Node/Python emitting API payloads or Fluent
source from the spec) do the repetitive structure; the model reviews and handles residuals. The
model must never hand-type hundreds of rows the spec already holds — that is where transcription
defects (and tokens) come from.

## Phase 4 — Verify: build success ≠ correct

Delegate to the **`catalog-verifier` agent** with the spec paths. It diffs instance vs spec
field-by-field in an isolated context and returns GREEN / DEFECTS / BLOCKED. The builder never
grades its own homework. Fix defects (≤3 attempts per root cause), re-verify; a standing
BLOCKED goes to the user — never report done past it.

## Phase 5 — Record

- Update the engagement build-state doc (what's built, active container, in-progress item).
- Write a batch report (built / verified / pending decisions).
- **Any new trap discovered → add to `references/traps.md` with its verification command.**
  A trap paid for twice is a process failure.
- Transport hygiene: verify capture (`sys_update_xml`), delete temp scheduled jobs, export the
  translations XML separately (T13, T15).

## Trap checklist

Read `references/traps.md` **before Phase 3** and again at any unexplained symptom — most
"mysteries" in catalog building are a known trap. Every entry: symptom → cause → rule → verify
command.
