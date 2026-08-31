defmodule Vutuv.Repo.Migrations.AddFediverseReshareRecencyIndexes do
  use Ecto.Migration

  # The feed's boost source reads `fediverse_post_boosts` newest-first with a
  # LIMIT, and no index led with the column it orders by — so Postgres fetched
  # the whole table, joined it, and top-N-sorted the result to hand back eleven
  # rows. `posts` has had `posts_recency_index` for exactly this since the feed
  # was built; this table never got its own.
  #
  # It is the one of the nine sources that will keep getting worse, because it
  # is the fediverse firehose: one row per reshare by any remote account any
  # member here follows, so it grows with the network rather than with vutuv.
  # Measured on the production copy (2026-08-31, 1,535 rows) by building the
  # index inside a rolled-back transaction and re-planning the real query:
  # **2.55 ms -> 0.048 ms**, with the scan going from 1,535 rows and 3,700
  # shared buffers to 27 rows and 79. Confirmed again on a whole page build
  # afterwards — the source's buffers fell from 3,700 to 81. That is the
  # difference between a source whose cost tracks the size of the table and one
  # whose cost tracks the size of the page.
  #
  # A composite leading with the account (`remote_account_id, announced_at`) was
  # measured too and the planner did not use it: the ordering is what it needs
  # to walk, and the account filter arrives as a hash join.
  #
  # **Only this one table**, deliberately. The three sibling reshare tables
  # (`fediverse_post_reposts`, `fediverse_note_reposts`, `fediverse_notes`) have
  # the same query shape and no such index, and indexing them was measured as
  # well — at 65, 0 and 40 rows Postgres rightly keeps its sequential scan, so
  # they gained nothing and would have cost write amplification on the inbox
  # path, which is hot. They grow with local activity rather than with the
  # network; the day one of them is a five-figure table it wants the same two
  # lines, and this comment is the note to whoever measures it then.
  #
  # Built CONCURRENTLY (so no transaction and no migrator lock), and N-1
  # compatible in the strongest sense: it adds nothing the old release reads and
  # only speeds up a query both releases already run.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:fediverse_post_boosts, ["announced_at DESC", "id DESC"],
        name: "fediverse_post_boosts_recency_index",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:fediverse_post_boosts, ["announced_at DESC", "id DESC"],
        name: "fediverse_post_boosts_recency_index",
        concurrently: true
      )
    )
  end
end
