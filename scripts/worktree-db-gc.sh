#!/usr/bin/env bash
#
# Drop the development and test databases whose git worktree is gone.
#
#   scripts/worktree-db-gc.sh            # say what is orphaned, touch nothing
#   scripts/worktree-db-gc.sh -y         # drop it
#   scripts/worktree-db-gc.sh --all      # also list every other vutuv database
#   scripts/worktree-db-gc.sh --quiet    # print nothing when there is nothing
#
# WHY THIS EXISTS
#   Every worktree session runs against its own pair of databases,
#   `vutuv1_dev_<name>` and `vutuv1_test_<name>`, ~115 MB and ~40 MB, created by
#   the `cw` shell function. Nothing removes them again. A session tears its own
#   worktree down from the inside (ExitWorktree, `git worktree remove`,
#   `gh pr merge --delete-branch`) and all three of those know only about git,
#   while `cwrm` — the one command that does drop the pair — can only run from
#   the main checkout, where by then nobody remembers the name. So the pairs
#   pile up: 33 databases and 1.7 GB by 2026-09-02, 15 and 1.3 GB by 2026-09-10.
#
#   `cwgc` in ~/.zshrc was the answer and cannot be the whole one, because a
#   shell function only exists in a shell that sources ~/.zshrc. A launchd job,
#   a git hook, a Claude session's Bash call: none of them do, and those are
#   exactly the places where the sweep could run without anybody remembering it.
#   Hence a file on disk. The shell function stays as the short spelling, and
#   `cw` runs this before it creates the next worktree — the one recurring
#   moment that is reliably in the main checkout.
#
# WHAT IS SAFE TO DROP, AND WHAT MAKES IT SAFE
#   A worktree is live if git still lists it (.git/worktrees/<name>) or if a
#   bare directory survives under .claude/worktrees/<name> — a directory git has
#   forgotten can still hold uncommitted work, so its databases stay. Beyond
#   that, three guards, because the failure this script must never have is
#   dropping the database out from under a working session:
#     * the shared `vutuv1_dev` and `vutuv1_test` are never candidates,
#     * neither is any database with an open connection (a suite mid-run, a dev
#       server): waiting costs one more run, dropping costs somebody their work,
#     * and if `git worktree list` fails, nothing is dropped at all, because an
#       empty list of live worktrees reads exactly like "everything is garbage".
#
#   Three shapes qualify. The worktree pair above; the main checkout's
#   `MIX_TEST_PARTITION` databases (`vutuv1_test<partition>`, no underscore —
#   which is why `cwgc`'s old `vutuv1_test\_%` pattern never saw them: 86 of
#   them held 1.9 GB on 2026-09-05); and the `vutuv_upgrade_path_test*_<pid>`
#   databases an aborted upgrade-path test leaves behind. Everything else that
#   starts with `vutuv` is listed under --all and never touched.

set -uo pipefail

: "${PGHOST:=localhost}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGUSER PGPASSWORD

DROP=0
ALL=0
QUIET=0

die() { echo "worktree-db-gc: $*" >&2; exit 1; }

# --quiet is for the automatic run (`cw`, before it creates the next worktree):
# it has to cost nothing to read when there is nothing to do, which is almost
# every time. What was actually dropped still goes to stderr below — going
# quiet about a deletion is not the same as going quiet about a no-op.
say() { [ "$QUIET" = 1 ] || echo "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fail closed, loudly. Without worktree_db_name every worktree name comes out
# empty, and an empty name is not a harmless blank: it makes every live
# worktree unrecognisable, which reads as "all of them are garbage".
[ -f "$SCRIPT_DIR/worktree-name.sh" ] ||
  die "$SCRIPT_DIR/worktree-name.sh fehlt — ohne die Namensregel wird hier nichts entschieden."
# shellcheck source=scripts/worktree-name.sh
. "$SCRIPT_DIR/worktree-name.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)   DROP=1 ;;
    --all)      ALL=1 ;;
    -q|--quiet) QUIET=1 ;;
    # The hook test/vutuv/worktree_test.exs pulls on to prove this script and
    # Vutuv.MixProject.worktree_name/1 still spell a worktree the same way.
    --db-name)  [ $# -ge 2 ] || die "--db-name braucht einen Namen."
                worktree_db_name "$2"; echo; exit 0 ;;
    -h|--help)  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unbekannte Option $1" ;;
  esac
  shift
done

gitdir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
  die "kein git-Repository."
root=${gitdir%/.git}
root=${root%/}
[ -f "$root/mix.exs" ] || die "$root sieht nicht wie der vutuv-Checkout aus."

# Asked only as a health check: if git cannot say what is live, we do not know
# either, and a sweep that does not know that is a sweep that deletes everything.
git -C "$root" worktree list >/dev/null 2>&1 || die "git worktree list schlug fehl, nichts angefasst."

live=()
for d in "$root"/.git/worktrees/*/ "$root"/.claude/worktrees/*/; do
  [ -d "$d" ] || continue
  n=${d%/}
  live+=("$(worktree_db_name "${n##*/}")")
done

# One query, not one per database: the sweep runs on every `cw`, and the list of
# candidates is long exactly when the databases are junk (86 partition databases
# once), so a connection count per candidate would be 86 psql processes to learn
# that there is nothing to do.
rows=$(psql -d postgres -tAF' ' -c "
  select d.datname, coalesce(a.n, 0)
    from pg_database d
    left join (select datname, count(*) as n from pg_stat_activity group by datname) a
      on a.datname = d.datname
   where d.datname like 'vutuv%'
     and d.datname not in ('vutuv1_dev', 'vutuv1_test')
   order by 1") ||
  die "Postgres antwortet nicht (PGHOST=$PGHOST PGUSER=$PGUSER)."

doomed=()
busy=()
other=()

# bash 3.2 (macOS /bin/bash) treats "${arr[@]}" on an empty array as an unbound
# variable under `set -u`, hence the ${arr[@]+…} spelling at every expansion.
while read -r db conns; do
  [ -n "$db" ] || continue

  keep=0
  case "$db" in
    vutuv1_dev_*)
      # Exact: a dev database carries the worktree name and nothing else.
      rest=${db#vutuv1_dev_}
      for l in ${live[@]+"${live[@]}"}; do
        [ "$rest" = "$l" ] && { keep=1; break; }
      done
      ;;
    vutuv1_test_*)
      # Prefix: config/test.exs appends MIX_TEST_PARTITION to the worktree
      # name, so vutuv1_test_<name><partition> belongs to <name> too.
      rest=${db#vutuv1_test_}
      for l in ${live[@]+"${live[@]}"}; do
        case "$rest" in "$l"*) keep=1; break ;; esac
      done
      ;;
    vutuv1_test*|vutuv_upgrade_path_test*)
      # The main checkout's partition databases and the pid-suffixed leftovers
      # of an aborted upgrade-path test. Single-use, both of them.
      ;;
    *)
      other+=("$db")
      continue
      ;;
  esac

  [ "$keep" = 1 ] && continue

  if [ "$conns" -gt 0 ]; then
    busy+=("$db")
  else
    doomed+=("$db")
  fi
done <<< "$rows"

if [ "$ALL" = 1 ] && [ "${#other[@]}" -gt 0 ]; then
  say "Nicht von diesem Werkzeug verwaltet, bleibt in jedem Fall stehen:"
  printf '  %s\n' "${other[@]}"
fi

if [ "${#busy[@]}" -gt 0 ]; then
  say "In Benutzung, bleibt stehen (offene Verbindungen):"
  printf '  %s\n' "${busy[@]}"
fi

if [ "${#doomed[@]}" -eq 0 ]; then
  say "Nichts verwaist."
  exit 0
fi

if [ "$QUIET" = 0 ]; then
  list=$(IFS=,; echo "${doomed[*]}")
  psql -d postgres -P pager=off -c \
    "select datname, pg_size_pretty(pg_database_size(datname)) as groesse
       from pg_database where datname = any('{$list}') order by 1"
fi

if [ "$DROP" = 0 ]; then
  echo "worktree-db-gc: ${#doomed[@]} Datenbanken ohne Worktree. Löschen: $0 -y" >&2
  exit 0
fi

status=0
for db in "${doomed[@]}"; do
  # --force, because a single leftover connection would otherwise leave the
  # database standing forever.
  if dropdb --force --if-exists "$db"; then
    echo "worktree-db-gc: $db gelöscht." >&2
  else
    echo "worktree-db-gc: $db blieb stehen." >&2
    status=1
  fi
done

exit $status
