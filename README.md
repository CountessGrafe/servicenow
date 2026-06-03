# SolvVision ServiceNow Plugins for Claude Code

A Claude Code plugin marketplace for ServiceNow development on the SDK (Fluent / now-sdk).

## 🧪 New here and need to test something with ATF?

**Start with the [ATF Testing Handbook](plugins/atf-skills/HANDBOOK.md).** It's a ~10-minute,
instance-agnostic onboarding guide: install, per-instance setup, the daily `/atf-verify` workflow, a
catalog-item-with-flow worked example, and troubleshooting. Then `plugins/atf-skills/README.md` has the
architecture and reference.

## Plugins

| Plugin | What it does | Start here |
|---|---|---|
| **atf-skills** | Autonomous ATF testing — author, deploy, run, and **self-heal** ATF tests on any project/instance, with an audit report. Skill + `atf-tester` subagent + `/atf-verify` command + post-deploy hook. | [HANDBOOK](plugins/atf-skills/HANDBOOK.md) · [README](plugins/atf-skills/README.md) |
| **servicenow-skills** | HRSD service creation, SDK patterns, and platform runbooks. | `plugins/servicenow-skills/skills/` |

## Install

In Claude Code:

```
/plugin   → add this marketplace (CountessGrafe/servicenow)
          → enable the plugin you need (e.g. atf-skills)
```

Reload the window/session if the new commands/agents don't appear immediately.

## Layout

```
.claude-plugin/marketplace.json     # marketplace manifest (lists the plugins)
plugins/
├── atf-skills/                     # autonomous ATF testing  →  see HANDBOOK.md
└── servicenow-skills/              # HRSD + platform skills
```
