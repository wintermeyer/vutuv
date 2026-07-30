defmodule Vutuv.Repo.Migrations.CoverVisibleUsersIndex do
  use Ecto.Migration

  # `users_visible_index` (20260725170422) made the public-visibility gate an
  # index question, but the gated queries also read `suspended_until` (the one
  # time-dependent arm that cannot live in the predicate), so every pass over
  # the ~5.5k visible members still fetched their heap rows — a bitmap heap
  # scan over 1,228 blocks, ~12ms inside each follower/followee count on the
  # profile. Rebuilding the index with `INCLUDE (suspended_until)` turns that
  # pass into an index-only scan: the same count measured 14.3ms -> 0.99ms on
  # the production copy. (Index-only needs a reasonably fresh visibility map;
  # until autovacuum catches up the plan just does a few heap fetches, which
  # is still far cheaper than fetching every row.)
  #
  # Keep the predicate in step with `Vutuv.Moderation.Query`'s two macros —
  # `visibility_index_test.exs` fails when the implication breaks. N-1 safe:
  # the old release's queries plan onto the new index identically (same
  # predicate, wider payload); both exist only for the moment between the two
  # steps. Built CONCURRENTLY, so no transaction / migrator lock.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @visible_predicate ~s|("email_confirmed?" IS NULL OR "email_confirmed?") AND frozen_at IS NULL AND deactivated_at IS NULL AND unreachable_at IS NULL|

  def up do
    create_if_not_exists(
      index(:users, [:id],
        name: "users_visible_covering_index",
        include: [:suspended_until],
        where: @visible_predicate,
        concurrently: true
      )
    )

    drop_if_exists(index(:users, [:id], name: "users_visible_index", concurrently: true))
  end

  def down do
    execute("""
    CREATE INDEX IF NOT EXISTS users_visible_index ON users (id)
    WHERE ("email_confirmed?" IS NULL OR "email_confirmed?")
      AND frozen_at IS NULL
      AND deactivated_at IS NULL
      AND unreachable_at IS NULL
    """)

    drop_if_exists(
      index(:users, [:id], name: "users_visible_covering_index", concurrently: true)
    )
  end
end
