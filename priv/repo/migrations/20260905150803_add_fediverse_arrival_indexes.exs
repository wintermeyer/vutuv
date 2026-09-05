defmodule Vutuv.Repo.Migrations.AddFediverseArrivalIndexes do
  use Ecto.Migration

  # The shell's "Feed" badge counts what has arrived since the member last read
  # their feed, and for a post from another server "arrived" is the moment it
  # reached us rather than the time its origin stamped on it minutes earlier
  # (`Vutuv.Fediverse.window_clock/3` holds that reasoning and the measurement).
  # So the badge's window now reads `fediverse_posts.received_at` and
  # `fediverse_post_boosts.inserted_at`, while both sources keep ordering by the
  # origin's clock.
  #
  # That split is what these two indexes pay for. Every existing index on these
  # tables leads with the ordering column (`published_at`, `announced_at DESC`),
  # so the new bound had nothing to walk and both sources fell back to a
  # sequential scan — measured on the production copy for the member with the
  # most remote follows (105 accounts, 7,709 cached posts, 2,183 boosts):
  #
  #   fediverse_posts   8.06 ms / 1,277 buffers  ->  0.03 ms / 7 buffers
  #   post_boosts       0.72 ms /    52 buffers  ->  0.03 ms / 7 buffers
  #
  # Plain single-column indexes, because that is what measured best: the badge's
  # window is short, so the arrival column alone is the selective one, and the
  # account filter costs nothing after it. A composite leading with the account
  # (`remote_account_id, received_at`) was measured too and was worse at every
  # window size (308 buffers over a day against 17) — it walks one range per
  # followed account instead of one range over the window.
  #
  # Built CONCURRENTLY (so no transaction and no migrator lock), and N-1
  # compatible in the strongest sense: the previous release reads neither index
  # and neither changes a result, they only give the new query something to walk.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:fediverse_posts, [:received_at],
        name: "fediverse_posts_received_at_index",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:fediverse_post_boosts, [:inserted_at],
        name: "fediverse_post_boosts_inserted_at_index",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:fediverse_posts, [:received_at],
        name: "fediverse_posts_received_at_index",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:fediverse_post_boosts, [:inserted_at],
        name: "fediverse_post_boosts_inserted_at_index",
        concurrently: true
      )
    )
  end
end
