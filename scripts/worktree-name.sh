# The database name a linked git worktree gets — sourced, never executed.
#
# Character for character what `Vutuv.MixProject.worktree_name/1` derives from
# git's own name for the worktree: lowercased, every run of non-alphanumerics
# folded to a single `_`, cut to 20 characters so `vutuv1_test_<name><partition>`
# stays inside Postgres' 63-byte identifier limit.
#
# It lives in a file of its own because two shell scripts need it and a second
# copy of this one line is how a LIVE session's database ends up on a delete
# list: `scripts/worktree-db-gc.sh` decides from this name which databases have
# no worktree left, and `scripts/restore-snapshot.sh` decides from it which
# worktree gets which image links. `test/vutuv/worktree_test.exs` holds this
# copy and the Elixir one against the same fixtures.
worktree_db_name() {
  printf %s "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/_/g' | cut -c1-20
}
