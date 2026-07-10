---
name: catalog-spec-authoring
description: Use when turning client requirements for Service Catalog items (Excel workbooks, Jira stories, workshop notes, prose documents) into machine-verifiable per-item YAML specs BEFORE any build starts; captures SOLVVision's spec-first pipeline, the verbatim-fidelity contract, the deterministic-extraction rule, and the TBD/deviation human gate. Invoke whenever catalog items are about to be built from client-provided requirements, or when auditing an existing story/spec against its source.
---

# Catalog Spec Authoring — requirements → machine-verifiable specs

**The prime rule: client text is data, not prose to improve.** An LLM that retypes requirements
paraphrases them; a script that copies cells cannot. Every defect class this skill guards against
(paraphrased descriptions, invented translations, renamed variables, dropped columns) was found in a
real audit of LLM-authored prose stories — and disappeared when specs became script-extracted YAML.

This skill owns **Phase 1** of the catalog delivery pipeline (overview in
`catalog-item-builder`, which owns the build). The output of this skill is one
`specs/<ITEM-ID>.yaml` per catalog item — the single input to the build and the single reference
for verification. Prose stories, if the engagement wants them, are *generated from the spec* for
human readers; they are never the build input.

## Step 0 — Lock the source of truth (once per engagement)

Before extracting anything:

1. **Identify the authoritative source and version.** Client workbooks routinely contain stale
   duplicate sheets (an outdated `Pattern` sheet next to the real `Pattern mit Flags bereinigt`
   was a live example). Ask the client/user to name the authoritative sheet or document — record
   the answer in the engagement's conventions doc. Never infer authority from sheet order or name.
2. **Map the relational model.** Requirements for one item are usually spread across joined sheets
   (item ↔ variable-set match ↔ variable sets ↔ choice lists ↔ flows ↔ tasks ↔ approvals). Write
   the join keys down before writing the extractor.
3. **Find the free-text columns** (`Notes`, `Anmerkung`, `Beschreibung`, task descriptions). These
   routinely carry the *implementation brief* — UI-policy logic, conditional visibility, CMDB
   side-effects, dynamic pricing — that never appears in structured columns. The extractor must
   carry them into the spec verbatim; the spec author must read them and convert each behavioral
   statement into a structured `behaviors:` entry (with provenance).
4. **Record the language architecture** as a locked decision: which language is primary for which
   artifact, and which is a translation layer. (Example from a German engagement: fulfiller-facing
   `sc_task` text German-primary; item names/descriptions/variable labels English-primary with
   German as `sys_translated_text`/`sys_translated` layer.) Never decide this per item.

## The fidelity contract (non-negotiable)

1. **Verbatim text.** Item names, short/long descriptions, variable labels, help texts, choice
   labels — copied character-for-character from the source, in every language the source provides.
   No paraphrasing, no synonyms, no "improving the wording". Mark such fields `lock: verbatim`.
2. **Never rename an internal name.** The client's field/variable internal name IS the name. A
   genuinely forced rename (real collision) is a **deviation entry + TBD for the human gate** —
   never a silent edit.
3. **Provided translations are copied verbatim** (`de_source: excel_verbatim` or equivalent).
   Where a needed translation is missing, generate one and **log it** under `corrections:` as a
   generated translation — provenance must distinguish client text from generated text.
4. **Every populated source column surfaces in the spec.** Dropping a column (help text is the
   classic casualty) is a defect. Build the column→spec map first, then check it per item.
5. **Typos may be fixed, but every fix is logged** under `corrections:` with the original.
6. **No invented values.** A blank source cell becomes `TBD` or `(not specified)` — never a
   plausible guess. Surface source-data defects; do not paper over them.
7. **Deviations are explicit.** Whenever the build will depart from a populated source cell, the
   spec carries a `deviations:` entry: *what the source says · what we build instead · decided by ·
   why*. A deferred/unbuildable requirement is a deviation, not an omission.

## Extraction procedure

1. **Write a deterministic extractor script** (Python + openpyxl for Excel; adapt per source).
   It joins the relational model by item id and emits one YAML per item. The LLM never retypes
   client text — the script copies it. Skeleton and schema: `references/spec-schema.md`.
2. Instance-resolved handles (catalog, category, taxonomy topic, group and set sys_ids) are
   emitted as `TO_RESOLVE` — resolution against the live instance is a separate later phase
   (`catalog-item-builder`), so specs stay instance-portable.
3. **The LLM's job is judgment, not transcription:** convert free-text Notes into structured
   `behaviors:` entries, classify ambiguities as TBDs, propose (and log) missing translations,
   and fill the corrections/deviations sections.
4. Statuses: `draft` → `spec_ready` (all checklist items pass, TBDs enumerated) → build phases
   rename/flag the file per engagement convention (e.g. `_built-` prefix) so remaining scope is
   always `ls`-able.

## Human gate — before any build

Present per item (or per batch): all **TBDs**, all **deviations**, all **generated translations**.
The user signs these off *before* Phase 2. Building on top of an unreviewed guess is how silent
spec drift becomes deployed wrong behavior.

## Pre-finalize checklist (run per spec)

- [ ] Every text field byte-for-byte equals the source cell (all languages) — or appears in `corrections:`.
- [ ] No internal/variable name differs from the source.
- [ ] Help texts present wherever the source has them, in every language provided.
- [ ] Choice tables carry value, all labels, order, active, and any price surcharge.
- [ ] Approval pattern matches the per-item source cell, or a `deviations:` entry explains why not.
- [ ] Placement (catalog/category/taxonomy) present per item — read from the source for THIS item,
      never copied from a sibling — or listed as a deviation if deferred.
- [ ] All free-text/Notes columns were read; behavioral content became `behaviors:` entries.
- [ ] No blank source cell was silently filled.
- [ ] `corrections:` and `deviations:` sections both present (even if explicitly "none").
- [ ] All unknowns are `TBD`/`TO_RESOLVE` markers, enumerated for the human gate.

## Verification (the spec is itself verifiable)

Because the spec is structured, fidelity is checkable by script, not by rereading: re-run the
extractor and diff against the spec's locked fields — any drift in a `lock: verbatim` field is a
defect. Run this check whenever the client ships a new workbook version.

---
*Companion skills: `catalog-item-builder` (Phases 0/2–5: bootstrap, resolve, build, verify,
record) and `catalog-fulfillment-flows` (the flow that fulfills the item). Conflicts: the source
wins on **content**; the engagement conventions doc wins on **build mechanics**.*
