---
name: hrsd-bootstrap-instance
description: One-time per-instance bootstrap for HRSD skills. Queries and caches stable reference sys_ids for the active ServiceNow instance. Invoked automatically by hrsd-new-service at startup — do not invoke manually unless refreshing stale data.
---

## Purpose

Cache stable instance constants so HRSD skills skip re-querying them on every invocation. Run once per instance; persists in memory indefinitely. A cold instance takes ~10 seconds to bootstrap; subsequent invocations are instant.

---

## Step 1: Identify the instance

Call `mcp__servicenow-mcp__get_current_instance`. Extract the hostname from the returned URL:
- `https://dev225965.service-now.com` → `dev225965`

Derive the memory file name: `reference_constants_<hostname>.md`

---

## Step 2: Check memory

Look for `reference_constants_<hostname>.md` in the project MEMORY.md index.

- **Found** → Read the file, load all constants into working context. Return them to the caller. **Stop here — do not re-query the instance.**
- **Not found** → Continue to Step 3.

---

## Step 3: Bootstrap queries

Run all of the following in parallel (single message, multiple tool calls):

```
query_records('sn_hr_core_service',
    query='active=true^header_config_opened_forISNOTEMPTY',
    fields='header_config_opened_for,header_config_subject_person',
    limit=1)

query_records('sn_hr_core_badge',
    query='name=HR',
    fields='sys_id,name',
    limit=1)

query_records('sc_catalog',
    query='titleLIKEHuman Resources',
    fields='sys_id,title',
    limit=1)

query_records('sys_scope',
    query='scope=sn_hr_core',
    fields='sys_id,scope',
    limit=1)

query_records('m2m_connected_content',
    query='catalog_itemISNOTEMPTY',
    fields='content_type',
    limit=1)

query_records('sys_db_object',
    query='name=sys_user',
    fields='name,create_access,write_access',
    limit=1)

get_system_property('glide.appcreator.company.code')
```

Also query one representative topic per HR domain — pick whichever are present on the instance:

```
query_records('sn_hr_core_topic_detail',
    query='active=true',
    fields='sys_id,name,topic_category',
    limit=20)
```

---

## Step 4: Save to memory

Write the file `reference_constants_<hostname>.md` to the project memory directory using this template:

```markdown
---
name: reference_constants_<hostname>
description: Stable sys_ids for <instance_url> — cached on first HRSD bootstrap. Delete after a PDI clone or full instance reset.
metadata:
  type: reference
---

Instance: <instance_url>
Cached: <YYYY-MM-DD>

## Core HRSD constants

header_config_opened_for: <sys_id>
header_config_subject_person: <sys_id>
badge_hr: <sys_id>
hr_catalog: <sys_id>
sn_hr_core_scope_sys_id: <sys_id>
m2m_content_type: <sys_id>

## Vendor prefix enforcement

company_code: <value from glide.appcreator.company.code>
vendor_prefix_required: x_<value>_*

## Protected table flags

sys_user_create_access: <true|false>
sys_user_write_access: <true|false>

## Topic details (semi-stable — verify name if a sys_id resolves wrong)

<list each topic detail: name: sys_id>
```

Add a one-line pointer in MEMORY.md:
```
- [Instance constants: <hostname>](reference_constants_<hostname>.md) — cached HRSD sys_ids for <instance_url>. Delete after PDI clone.
```

---

## Step 5: Emit a pre-flight verdict

After loading or bootstrapping, emit a compact summary before returning to the caller:

```
Bootstrap: <hostname>
✅ badge_hr, header_config_opened_for/subject_person, hr_catalog, sn_hr_core_scope — loaded
✅ m2m_content_type — loaded
⚠️  sys_user.create_access = false → flows writing sys_user must live in sn_hr_core scope
✅ vendor prefix required: x_<code>_*
```

Flag any missing values (query returned empty) so the caller knows to handle them manually.

---

## Staleness rules

| Event | Action |
|---|---|
| PDI clone | Delete `reference_constants_<hostname>.md` — all sys_ids change |
| Admin renamed a topic | Delete the file if a topic sys_id resolves to the wrong name |
| Australia / platform upgrade | Re-check `glide.appcreator.company.code` and `sys_user.create_access` — delete and re-bootstrap if uncertain |
| Routine upgrade (no clone) | No action — core sys_ids survive in-place upgrades |

Topics and categories are the only semi-stable values — admins can rename them. The file header notes this. If a topic sys_id resolves to the wrong name on the instance, delete the file and re-run the bootstrap.
