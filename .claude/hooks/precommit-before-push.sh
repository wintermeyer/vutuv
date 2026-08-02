#!/usr/bin/env bash
# PreToolUse(Bash) gate: before any `git push`, run the project's full precommit
# (`mix precommit` = compile --warnings-as-errors, deps.unlock --unused, format
# check, credo --strict, mix test) and BLOCK the push if it fails. CI runs the
# same gate and a push to `main` auto-deploys to production, so a failing
# precommit must never be pushed.
#
# The tool call arrives as JSON on stdin. Exit 2 blocks the call and feeds the
# reason back to Claude; exit 0 lets it through.
#
# Two rules this script exists to honour, both learned the hard way (2026-08-02):
#
#   1. CHECK THE TREE THE PUSH COMES FROM. This used to `cd $CLAUDE_PROJECT_DIR`,
#      which names the *session's* project directory, not the worktree the push
#      runs in. Several worktrees share this repo, so the gate would run
#      `mix precommit` in one checkout and wave through a push from another —
#      reporting green for code it had never compiled. The push's own directory
#      is resolved below, and when it cannot be resolved the push is BLOCKED.
#      Every degraded path here fails closed: silence must never mean "allow".
#
#   2. RECOGNISE A PUSH BY ITS SHAPE, NOT BY A SUBSTRING. This used to match
#      `*"git push"*` anywhere in the command line, which over-matched (a plain
#      `grep "git push"` was blocked) and, far worse, under-matched: the common
#      `git -C <dir> push` does not contain the string "git push" and sailed
#      straight past the gate. Each segment of the command line is now tokenised
#      and a git invocation's subcommand is read properly.
#
# LIMITS — read this as a backstop, not a sandbox. It sees `git` invoked
# directly in a segment of one Bash tool call. It cannot see a push made through
# a wrapper it does not know (`bash -c '…'`, `xargs git`, a shell function, a
# script, a Makefile target, an editor's VCS integration), and quoting is
# approximated rather than parsed. It is the last automatic reminder before
# production, not a guarantee that nothing else can push.
#
# Run `bash precommit-before-push.sh --explain < payload.json` to print the
# decision (ALLOW / PUSH <toplevel> / BLOCK <reason>) without running precommit.
# `test/vutuv/precommit_hook_test.exs` drives that mode, so CI covers this file.
set -uo pipefail

explain=0
[ "${1:-}" = "--explain" ] && explain=1

block() {
  if [ "$explain" -eq 1 ]; then
    echo "BLOCK $1"
    exit 0
  fi
  echo "" 1>&2
  echo "BLOCKED: $1" 1>&2
  echo "CI runs the same gate, and pushing to main auto-deploys to production." 1>&2
  exit 2
}

allow() {
  [ "$explain" -eq 1 ] && echo "ALLOW"
  exit 0
}

payload=$(cat)

# Without `jq` the command line cannot be read at all, and an unreadable command
# must not be mistaken for a harmless one. Blocking every Bash call would brick
# the session, so narrow it to the dangerous case: if the raw payload so much as
# mentions git and push, refuse; otherwise let it through.
if ! command -v jq >/dev/null 2>&1; then
  case "$payload" in
    *git*push*)
      block "\`jq\` is not installed, so this push cannot be vetted. Install jq (\`brew install jq\`) or run \`mix precommit\` yourself before pushing."
      ;;
    *) allow ;;
  esac
fi

command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)
payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

# One layer of surrounding quotes, removed. Full shell quoting is not parsed —
# see LIMITS above.
strip_quotes() {
  local t=$1
  t=${t#\"}
  t=${t%\"}
  t=${t#\'}
  t=${t%\'}
  printf '%s' "$t"
}

# The command line, split into segments on the operators that separate one
# command from the next. Splitting inside a quoted string only produces extra
# segments that start with no command at all, which are ignored.
segments=$(printf '%s' "$command" | awk '{gsub(/&&|\|\||;|\||&/, "\n"); print}')

found_push=0
push_dir=""
# A `cd` in an earlier segment governs a push in a later one
# (`cd /tree && git push`), so the walk carries the last target along.
chain_dir=""

while IFS= read -r segment; do
  # Word-split on whitespace. Quoted arguments holding spaces are split too;
  # that can only cost us the *directory*, never the push detection.
  read -ra words <<<"$segment"
  [ "${#words[@]}" -eq 0 ] && continue

  # Skip leading `VAR=value` environment assignments.
  idx=0
  while [ "$idx" -lt "${#words[@]}" ]; do
    case "${words[$idx]}" in
      [A-Za-z_]*=*) idx=$((idx + 1)) ;;
      *) break ;;
    esac
  done
  [ "$idx" -lt "${#words[@]}" ] || continue

  argv0=$(strip_quotes "${words[$idx]}")
  case "${argv0##*/}" in
    cd)
      next=$((idx + 1))
      [ "$next" -lt "${#words[@]}" ] && chain_dir=$(strip_quotes "${words[$next]}")
      continue
      ;;
    git) ;;
    *) continue ;;
  esac

  # Walk git's own global options to find the subcommand. `-C <dir>` names the
  # tree the push runs in and is the whole reason this parse exists.
  dir_opt=""
  subcommand=""
  j=$((idx + 1))
  while [ "$j" -lt "${#words[@]}" ]; do
    w=$(strip_quotes "${words[$j]}")
    case "$w" in
      -C)
        j=$((j + 1))
        [ "$j" -lt "${#words[@]}" ] && dir_opt=$(strip_quotes "${words[$j]}")
        ;;
      -C?*) dir_opt=${w#-C} ;;
      # Global options that swallow the following word.
      -c | --git-dir | --work-tree | --namespace | --exec-path | --config-env)
        j=$((j + 1))
        ;;
      -*) : ;; # any other global option (including the `--opt=value` forms)
      *)
        subcommand=$w
        break
        ;;
    esac
    j=$((j + 1))
  done

  if [ "$subcommand" = "push" ]; then
    found_push=1
  elif [ -z "$subcommand" ]; then
    # No subcommand identified — an option this script does not know swallowed
    # it. Under-matching is the dangerous direction, so fall back to a bare
    # scan: a `push` token anywhere in a git invocation counts as a push.
    for w in "${words[@]}"; do
      [ "$(strip_quotes "$w")" = "push" ] && found_push=1 && break
    done
  fi

  if [ "$found_push" -eq 1 ]; then
    push_dir=${dir_opt:-$chain_dir}
    break
  fi
done <<<"$segments"

[ "$found_push" -eq 1 ] || allow

# Resolve the worktree the push actually runs in: an explicit `git -C <dir>`
# first, then a `cd` from the same command line, then the directory the tool
# call was made in. Anything unresolvable blocks.
dir=${push_dir:-$payload_cwd}
dir=${dir:-$PWD}

toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$toplevel" ] ||
  block "cannot tell which git worktree this push comes from (looked in: ${dir:-<empty>}). Refusing to guess."

[ -f "$toplevel/mix.exs" ] ||
  block "$toplevel is not the vutuv project root (no mix.exs), so the precommit gate cannot vouch for this push."

if [ "$explain" -eq 1 ]; then
  echo "PUSH $toplevel"
  exit 0
fi

cd "$toplevel" || block "cannot enter $toplevel."

echo "Running mix precommit in $toplevel …" 1>&2
if mise exec -- mix precommit 1>&2; then
  exit 0
fi

block "\`mix precommit\` failed in $toplevel — fix it before pushing."
