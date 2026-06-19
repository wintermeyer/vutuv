#!/usr/bin/env bash
# PreToolUse(Bash) gate: before any `git push`, run the project's full precommit
# (`mix precommit` = compile --warnings-as-errors, credo --strict, format check,
# mix test) and BLOCK the push if it fails. CI runs the same gate, and a push to
# `main` auto-deploys to production, so a failing precommit must never be pushed.
#
# The tool call arrives as JSON on stdin; we act only on `git push` commands and
# let every other Bash command through. Exit 2 blocks the tool call and feeds the
# precommit output back to Claude.
set -uo pipefail

command=$(jq -r '.tool_input.command // ""' 2>/dev/null)

case "$command" in
  *"git push"*) : ;;  # a push — fall through to the gate
  *) exit 0 ;;        # anything else — allow untouched
esac

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true

# Stream precommit output to stderr so a failure is surfaced back to Claude.
if mise exec -- mix precommit 1>&2; then
  exit 0
fi

echo "" 1>&2
echo "BLOCKED: \`mix precommit\` failed — fix it before pushing." 1>&2
echo "CI runs the same gate, and pushing to main auto-deploys to production." 1>&2
exit 2
