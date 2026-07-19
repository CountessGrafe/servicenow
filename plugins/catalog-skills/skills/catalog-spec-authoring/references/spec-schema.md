# Catalog item spec — YAML schema + extractor skeleton

One file per item: `specs/<ITEM-ID>.yaml`. Field names below are the contract the
`catalog-item-builder` recipe and the `catalog-verifier` agent both consume — keep them stable.

## Schema (annotated)

```yaml
meta:
  id: CI-XX-000                # client's item id
  status: spec_ready           # draft | spec_ready | built
  source_ref: "Pattern!row 42" # exact sheet/row (or ticket id) this was extracted from

placement:                     # ALWAYS per-item from the source — never copied from a sibling
  catalogs:
    - name: <catalog name as written in source>
      sys_id: TO_RESOLVE       # resolved against the instance in the Resolve phase
  category: { name: ..., sys_id: TO_RESOLVE }
  taxonomy_topic: { path: "Topic > Subtopic > Leaf", sys_id: TO_RESOLVE }

item:
  active: true
  name:                        # pattern repeats for short_description and description
    en: <verbatim>
    de: <verbatim or generated>
    de_source: excel_verbatim  # excel_verbatim | generated   ← provenance is mandatory
    lock: verbatim             # marks the field as script-copied client text — never edit
  short_description: { en, de, de_source, lock }
  description: { en, de, de_source, lock }    # block scalars; HTML preserved as-is
  meta_tags: <verbatim keyword list — do not re-order or edit>

pricing:
  price: 0                     # one-time
  recurring_price: 0
  recurring_frequency: monthly # only if recurring_price > 0

variable_sets:                 # ALL variables live in sets if that is the engagement standard
  - internal_name: <verbatim — NEVER renamed>
    title: { en, de }
    type: one_to_one           # one_to_one | one_to_many (MRVS)
    reuse: null                # existing set's sys_id → attach only, build nothing
    order: 100                 # io_set_item order
    condition: null            # conditional attachment, if the source specifies one
    variables:
      - name: <verbatim internal name, lock: verbatim>
        label: { en, de, de_source }
        type: { code: 6, name: single_line_text }   # keep BOTH; codes verified per instance
        mandatory: false
        default: null          # null = source blank (never invent)
        help_text: { en, de }  # null only if source truly blank
        reference: { table: ..., qualifier: ... }   # type 8 only — table is MANDATORY
        choices_ref: CL-012    # -> choice_lists entry
        order: 10

choice_lists:
  - id: CL-012
    choices:
      - { value: <verbatim>, label: { en, de }, order: 10, active: true,
          price_surcharge: 0 } # lands in question_choice.misc / rec_misc — see traps

behaviors:                     # structured from free-text Notes — Given/When/Then, not prose
  - source_ref: "Pattern!Notes row 42"
    kind: ui_policy            # ui_policy | client_script | script_include | data
    scenario: "<short name>"
    given: "<precondition — item/variable state, in source words where possible>"
    when: "<the trigger — a field change, a submit, a load>"
    then: "<the expected, observable outcome>"
    implementation: TBD        # decided at build; OOB-first rule applies
    # each entry is close to a ready-made ATF test case — keep it that concrete.

flow:                          # summary — full flow spec in catalog-fulfillment-flows terms
  id: FL-000
  name: { en, de }
  approval: { pattern: AP-003, notes: <verbatim> }
  fulfillment_behaviors:        # same Given/When/Then shape, for flow-level conditional logic
    - source_ref: "Flows!Notes row 12"
      scenario: "Approver fallback"
      given: "the CI has no managed_by_group set"
      when: "the approval step runs"
      then: "route to the Service Desk fallback group (via property lookup, never hardcoded)"
  tasks:
    - name: { de: <verbatim>, en: <reference> }    # fulfiller language per locked decision
      description: { de: <verbatim>, en: <reference> }
      assignment_group: { name: <verbatim>, sys_id: TO_RESOLVE }
      order: 1
      predecessors: []

corrections: []                # typo fixes + generated translations, each with the original
deviations: []                 # source-says / we-build / decided-by / why
tbd: []                        # every open question — the human gate reads this list
```

## Extractor skeleton (Python)

Adapt the joins to the engagement's source; keep the YAML emission properties (insertion order,
unicode, block scalars) — they make specs diffable.

```python
#!/usr/bin/env python3
"""extract_spec.py — verbatim catalog-item specs straight from the client source.
Joins the relational model by item id, emits one YAML per item under specs/.
All client text copied VERBATIM; unresolvable handles marked TO_RESOLVE."""
import sys, openpyxl, yaml

class Lit(str): pass                                  # block-scalar strings
yaml.add_representer(Lit, lambda d, s: d.represent_scalar(
    "tag:yaml.org,2002:str", s, style="|" if "\n" in s else None))
yaml.add_representer(dict, lambda d, x: d.represent_dict(x.items()))  # keep order

def rows(ws):                                         # sheet -> list[dict] by header row
    hdr = [ws.cell(1, c).value for c in range(1, ws.max_column + 1)]
    return [{hdr[c-1]: ws.cell(r, c).value for c in range(1, ws.max_column + 1)}
            for r in range(2, ws.max_row + 1)]

# per engagement: load sheets, forward-fill merged key columns, join by item id,
# assemble the schema above, yaml.dump(spec, f, allow_unicode=True, sort_keys=False)
```

Two extractor rules that matter more than the code:
1. **Forward-fill merged cells** on join-key columns before joining — Excel merges silently
   null out repeated keys and orphan the child rows.
2. **Emit `None` for blank cells** — never a default. Blanks become spec `null`/TBD so the
   fidelity contract's "no invented values" rule survives the pipeline.

## Verifying a spec against its source

```bash
python3 scripts/extract_spec.py <ITEM-ID>        # re-extract to a temp copy
diff <(yq 'del(.corrections,.deviations,.tbd,.behaviors[].implementation)' specs/<ID>.yaml) \
     <(yq 'del(.corrections,.deviations,.tbd,.behaviors[].implementation)' /tmp/<ID>.yaml)
```
Any diff in a `lock: verbatim` field = fidelity defect (or a new source version — check which).
