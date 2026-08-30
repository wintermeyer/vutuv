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
# Three rules this script exists to honour, each learned the hard way (the
# first two on 2026-08-02, the third on 2026-08-28):
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
#   3. DO NOT CHARGE A PUSH FOR AN ANSWER IT CANNOT GET. `mix precommit`'s
#      first four steps are seconds; its fifth is the ~9,100-test suite, which
#      is the whole cost (~300 s on a quiet machine, ~900 s when twenty
#      worktree sessions share it). None of the five steps can read a `docs/`
#      page, a `.github/` workflow or a top-level Markdown file, so a push
#      carrying only those buys nothing — #1774 paid that run nine times for
#      one Markdown file. Such a push is now skipped; see the exemption below
#      for what counts and, more importantly, what does not.
#
# LIMITS — read this as a backstop, not a sandbox. It sees `git` invoked
# directly in a segment of one Bash tool call. It cannot see a push made through
# a wrapper it does not know (`bash -c '…'`, `xargs git`, a shell function, a
# script, a Makefile target, an editor's VCS integration), and quoting is
# approximated rather than parsed. It is the last automatic reminder before
# production, not a guarantee that nothing else can push.
#
# Run `bash precommit-before-push.sh --explain < payload.json` to print the
# decision (ALLOW / SKIP <reason> / PUSH <toplevel> / BLOCK <reason>) without
# running precommit. `test/vutuv/precommit_hook_test.exs` drives that mode, so
# CI covers this file.
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

# The push goes through without the run, because the run could not have looked
# at any of it. Distinct from `allow` so `--explain` — and the test — can tell
# a push that was vetted apart from one that was waved past.
skip() {
  if [ "$explain" -eq 1 ]; then
    echo "SKIP $1"
    exit 0
  fi
  echo "precommit skipped: $1" 1>&2
  exit 0
}

# The files none of precommit's five steps can read. DENY FIRST, and that order
# is the whole point: a Markdown file that is itself a build or test input is
# not exempt for ending in `.md`. `priv/help/*.md` compiles into
# `VutuvWeb.HelpController`, `priv/dev_docs/*.md` into `DevDocController`, and
# `.claude/rules/design.md` is read and asserted on by the dark-mode tests — an
# extension-only rule would have skipped the gate on all three.
#
# The `*/*` arm is why the two Markdown arms are not one. In a `case` pattern
# `*` matches `/` as well, so a bare `*.md` exempts Markdown at ANY depth, not
# just at the top — `rel/overlays/notes.md` would have sailed past the gate
# even though `rel/` holds the release templates the deploy builds from. Only
# the directories named above are exempt at depth; everything else has to be a
# genuinely top-level file to qualify.
precommit_blind_to() {
  case "$1" in
    lib/* | test/* | config/* | priv/* | assets/* | scripts/* | .claude/* | rel/*) return 1 ;;
    mix.exs | mix.lock | .formatter.exs | .credo.exs) return 1 ;;
    docs/* | .github/* | LICENSE | NOTICE | CODEOWNERS) return 0 ;;
    */*) return 1 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
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
# Everything after the `push` subcommand, one argument per line: the remote, any
# refspecs, any options. The exemption below reads it to confirm this push
# really does carry the current branch and nothing besides.
push_args=""
push_args_unknown=0
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
    k=$((j + 1))
    while [ "$k" -lt "${#words[@]}" ]; do
      push_args="$push_args$(strip_quotes "${words[$k]}")
"
      k=$((k + 1))
    done
  elif [ -z "$subcommand" ]; then
    # No subcommand identified — an option this script does not know swallowed
    # it. Under-matching is the dangerous direction, so fall back to a bare
    # scan: a `push` token anywhere in a git invocation counts as a push.
    for w in "${words[@]}"; do
      [ "$(strip_quotes "$w")" = "push" ] && found_push=1 && push_args_unknown=1 && break
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

# A GitHub wiki lives in a repository of its own (`<repo>.wiki.git`) and can
# never hold a mix.exs: no suite, no CI, no deploy, so precommit has nothing to
# vouch for here and the gate would only make a wiki page unpublishable. Scoped
# to that one shape, the remote URL ENDING in `.wiki.git`, and a remote that
# cannot be read is not an exemption but an unanswered question, so it falls
# through to the block below.
if [ ! -f "$toplevel/mix.exs" ]; then
  origin=$(git -C "$toplevel" remote get-url origin 2>/dev/null)
  case "$origin" in
    *.wiki.git) allow ;;
  esac

  block "$toplevel is not the vutuv project root (no mix.exs), so the precommit gate cannot vouch for this push."
fi

# ── Does this push carry anything precommit could look at? ──────────────────
# The exemption is narrow on purpose: skip only when EVERY file the push newly
# puts on the remote is one `precommit_blind_to` vouches for. `mix.exs` is not
# among them — it is compiled and format-checked, and it decides what the suite
# builds at all — so any push touching it still pays the full gate.
#
# Rule 1 of this file governs here too. An unanswered question is not an
# exemption, so every way of not knowing — detached HEAD, an argument list this
# script could not read, a push naming some other ref, no merge base, a diff
# that came back empty — falls through to the full run rather than guessing.
gate=""

[ "$push_args_unknown" -eq 0 ] ||
  gate="the push's own arguments could not be read"

branch=""
if [ -z "$gate" ]; then
  branch=$(git -C "$toplevel" symbolic-ref --quiet --short HEAD 2>/dev/null)
  [ -n "$branch" ] || gate="HEAD is detached, so there is no branch to compare"
fi

# The first bare argument is the remote; anything bare after it is a refspec,
# and a refspec that is not this branch pushes something this diff never saw.
if [ -z "$gate" ]; then
  seen_remote=0
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    case "$arg" in
      --all | --mirror | --tags | --delete | -d | --prune)
        gate="\`$arg\` carries more than this branch"
        break
        ;;
      -*) ;;
      *)
        if [ "$seen_remote" -eq 0 ]; then
          seen_remote=1
        else
          case "$arg" in
            HEAD | "$branch" | "HEAD:$branch" | "$branch:$branch" | "HEAD:refs/heads/$branch" | "$branch:refs/heads/$branch") ;;
            *)
              gate="the push names \`$arg\`, not just the current branch"
              break
              ;;
          esac
        fi
        ;;
    esac
  done <<EOF
$push_args
EOF
fi

# What this branch wrote on its own, which is the merge base with the trunk —
# NOT the merge base with the tracking ref (`@{upstream}`). The moment a branch
# merges main in or rebases onto it, the tracking ref's merge base falls back
# behind that integration point, so the diff carries every file main changed
# meanwhile and no docs-only branch is docs-only twice. That is rule 3's own
# push, and reading the tracking ref would have exempted the first of those
# nine runs and charged the eight after it. Main's code was gated on main; what
# this push asks anybody to check is the work of the branch.
#
# The mirror case is the cost, and it is the direction this file always takes:
# a code branch whose follow-up push touches only documentation pays the gate a
# second time. That is also why the tracking ref is not kept as a fallback for
# a checkout with no trunk ref — it is the permissive reading, and rule 1 says
# an unanswered question is not an exemption.
#
# `git log HEAD --not --remotes` would name the pushed-for-the-first-time paths
# exactly, without a base at all. It is not used: a merge commit lists no paths
# without `--diff-merges`, and `--remotes` trusts every remote-tracking ref in
# the checkout, forks included. Both miss in the permissive direction.
base=""
if [ -z "$gate" ]; then
  for trunk in refs/remotes/upstream/main refs/remotes/origin/main; do
    base=$(git -C "$toplevel" merge-base "$trunk" HEAD 2>/dev/null) || base=""
    [ -n "$base" ] && break
  done

  [ -n "$base" ] || gate="nothing to compare this push against"
fi

# An empty list is the two cases at once — git failed, or the push carries no
# file change at all — and neither is a licence to skip.
if [ -z "$gate" ]; then
  changed=$(git -C "$toplevel" diff --name-only "$base" HEAD 2>/dev/null)

  if [ -z "$changed" ]; then
    gate="the file list came back empty"
  else
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      precommit_blind_to "$file" || {
        gate="$file"
        break
      }
    done <<EOF
$changed
EOF
  fi
fi

[ -n "$gate" ] ||
  skip "this branch adds only files \`mix precommit\` cannot read (docs, .github, top-level Markdown). CI still checks everything."

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
