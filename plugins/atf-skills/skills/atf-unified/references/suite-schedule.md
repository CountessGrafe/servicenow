# Phase 7 — Suite + Schedule

> On-demand reference for `atf-unified`. Read this file when wiring tests into a suite and scheduling a
> nightly run. The SDK `Record()` path is preferred (version-controlled, survives `--reinstall`); MCP is
> the fallback for projects with no SDK setup.

---

The SDK `Test()` API creates individual tests. Suites, suite memberships, and scheduled jobs can be authored with the SDK's `Record()` API — **this is the preferred approach** because it keeps them version-controlled alongside the tests and they survive `--reinstall`. MCP is the fallback for projects with no SDK setup.

**Preferred: SDK `Record()` path**

Register IDs in `keys.ts` first:

```typescript
'suite-my-artifact': { table: 'sys_atf_test_suite', id: '<32-char-hex>' }
'suite-my-artifact-test-1': { table: 'sys_atf_test_suite_test', id: '<32-char-hex>' }
'schedule-my-artifact-nightly': { table: 'sysauto_script', id: '<32-char-hex>' }
```

Then in a `.now.ts` file (e.g. `src/fluent/suites/MyArtifactSuite.now.ts`):

```typescript
import { Record } from '@servicenow/sdk/core'

export const MyArtifactSuite = Record({
    $id: Now.ID['suite-my-artifact'],
    table: 'sys_atf_test_suite',
    data: {
        name: 'Suite — MyArtifact',
        active: true,
    },
})

// One Record per test; increment order by 100
// Now.ID[key].id is declared in keys.ts and should resolve at build time inside Record({ data }).
// Verify this compiles in your SDK version before adopting it — if the build rejects it,
// fall back to the literal sys_id string from keys.ts.
export const MyArtifactSuiteTest1 = Record({
    $id: Now.ID['suite-my-artifact-test-1'],
    table: 'sys_atf_test_suite_test',
    data: {
        test_suite: Now.ID['suite-my-artifact'].id,
        test: Now.ID['test-my-artifact'].id,
        order: 100,
    },
})

// Nightly schedule — Now.ID[key].id bakes the sys_id into the script at build time
export const MyArtifactSchedule = Record({
    $id: Now.ID['schedule-my-artifact-nightly'],
    table: 'sysauto_script',
    data: {
        name: 'Scheduled — Suite MyArtifact (Nightly)',
        script: `var gr = new GlideRecord('sys_atf_test_suite'); gr.get('${Now.ID['suite-my-artifact'].id}'); new SncATFTestSuiteRunner(gr).run();`,
        run_type: 'daily',
        run_time: '1970-01-01 06:00:00',
        active: true,
    },
})
```

**Fallback: MCP (no SDK project)**

Use MCP only when no `now-sdk` project exists to commit to. MCP-created suites and scheduled jobs are wiped on `npm run deploy -- --reinstall` — they do not live in the SDK XML and must be recreated after every reinstall.

```
mcp create_record(
    table: 'sys_atf_test_suite',
    fields: {
        name: 'Suite - <ArtifactName>',
        description: '<what this suite covers>',
        active: 'true',
        sys_scope: '<scope_sys_id>'
    }
)

# Then for each test (increment order by 100):
mcp create_record(
    table: 'sys_atf_test_suite_test',
    fields: {
        test_suite: '<suite_sys_id>',
        test: '<test_sys_id>',
        order: '100'
    }
)

mcp create_scheduled_job(
    name: 'Scheduled - Suite <ArtifactName> (Nightly)',
    script: "var gr = new GlideRecord('sys_atf_test_suite');\ngr.get('<suite_sys_id>');\nnew SncATFTestSuiteRunner(gr).run();",
    run_type: 'daily',
    run_time: '1970-01-01 06:00:00',
    active: true
)
```
