defmodule Vutuv.Repo.Migrations.AddUsersVisibilityPartialIndex do
  use Ecto.Migration

  # The "is this member publicly visible" gate — `account_confirmed_row/1 and
  # not account_hidden_row/1` from `Vutuv.Moderation.Query` — guards ~55 query
  # sites across 13 modules (search, the follower/following/connection lists,
  # the tag pages, the directory, the fediverse actor). It has never had an
  # index, so every one of those queries read the whole users table.
  #
  # That is far more wasteful than the row count suggests: on the production
  # data only 5,549 of 60,527 members pass the gate (9%) — the other 91% are
  # legacy accounts that never confirmed their email. Each gated query was
  # scanning 14 MB of heap to find a set that fits in a few index pages.
  #
  # The predicate deliberately leaves out the `suspended_until > now()` arm:
  # `now()` is not immutable, so it cannot appear in an index predicate. It
  # stays a cheap filter on the rows the index returns, and Postgres still
  # proves the implication (the query's WHERE is this predicate AND the
  # suspension test, which only narrows it) — verified on the production copy:
  # the planner picks this index for the gated queries and drops the seq scan.
  #
  # Keep the predicate in step with those two macros. If a future hidden state
  # joins the gate and this index is not updated, the implication no longer
  # holds and every gated query silently falls back to the seq scan — which is
  # what `test/vutuv/moderation/visibility_index_test.exs` fails on.
  #
  # Plain (non-concurrent) create, like the other index migrations here: users
  # is a 14 MB table, so the build takes well under a second.
  def up do
    execute("""
    CREATE INDEX users_visible_index ON users (id)
    WHERE ("email_confirmed?" IS NULL OR "email_confirmed?")
      AND frozen_at IS NULL
      AND deactivated_at IS NULL
      AND unreachable_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX users_visible_index")
  end
end
