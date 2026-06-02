#!/usr/bin/env bash
# atf-postdeploy.sh — PostToolUse hook for the atf-skills plugin.
#
# After a `npm run deploy`, nudge the main agent to verify the deploy via the atf-tester subagent.
# Suppresses itself while atf-tester is mid-run (a fresh lock file) so the agent's own heal-loop
# deploys do not recursively re-trigger verification.
#
# Reads the hook payload as JSON on stdin; emits PostToolUse additionalContext as JSON on stdout.
# No jq dependency — uses substring matching so it is portable on a stock macOS/Linux shell.

set -euo pipefail

input="$(cat)"

# 1. Only react to `npm run deploy` invocations — ignore every other Bash command.
case "$input" in
  *"npm run deploy"*) ;;
  *) exit 0 ;;
esac

# 2. Recursion guard: if atf-tester is already running (lock < 30 min old), stay silent.
LOCK="atf-reports/.atf-verify.lock"
if [ -f "$LOCK" ] && find "$LOCK" -mmin -30 2>/dev/null | grep -q .; then
  exit 0
fi

# 3. Nudge the main agent. additionalContext is advisory — the agent ignores it if already verified.
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "A `npm run deploy` just completed. Per the ATF policy, verify the deployed artifact(s): delegate to the `atf-tester` subagent (or run /atf-verify) to build and run ATF coverage for whatever changed this session, then handle any BLOCKED verdict at the user gate. If these artifacts were already verified this session, ignore this nudge."
  }
}
JSON
