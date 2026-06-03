#!/usr/bin/env bash
#
# PostToolUse hook. When a vutuv design-system source is edited, inject a
# reminder asking the agent to keep `.claude/rules/design.md` in sync with the
# real design language. Editing design.md itself never triggers it.
#
# Reads the tool-call JSON on stdin; extracts tool_input.file_path with python3
# (no jq dependency). Always exits 0 — a reminder hook must never block a tool.

input="$(cat)"

file="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
' 2>/dev/null)"

case "$file" in
  */.claude/rules/design.md)
    : # the design rule itself — never remind (avoid a loop)
    ;;
  */assets/css/components.css|*/assets/css/app.css|*/lib/vutuv_web/components/ui.ex)
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"You just edited a vutuv design-system source (assets/css/components.css, assets/css/app.css, or lib/vutuv_web/components/ui.ex). If this changed the visual language — design tokens, component classes, or card/button/form/shell styling — update .claude/rules/design.md so the design-system rule stays in sync with reality. If it was an unrelated tweak, ignore this."}}
JSON
    ;;
esac

exit 0
