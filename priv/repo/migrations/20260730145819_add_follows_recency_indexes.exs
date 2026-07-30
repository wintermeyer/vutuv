defmodule Vutuv.Repo.Migrations.AddFollowsRecencyIndexes do
  use Ecto.Migration

  # The profile header's follower/following previews (`Follow.latest/2`) read a
  # member's newest follows with a LIMIT after joining the visibility gate, and
  # the plain per-side indexes force Postgres to fetch and top-N-sort every one
  # of the member's follows first (5ms+ for a few hundred rows, on every
  # profile mount, twice per visit). With recency in the index the scan walks
  # newest-first and stops as soon as the limit is full: 5.3ms -> 0.2ms on the
  # production copy. Built CONCURRENTLY (no transaction / migrator lock), and
  # N-1 compatible: it only speeds up existing queries.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:follows, ["followee_id", "inserted_at DESC", "id DESC"],
        name: "follows_followee_recency_index",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:follows, ["follower_id", "inserted_at DESC", "id DESC"],
        name: "follows_follower_recency_index",
        concurrently: true
      )
    )

    # Both single-column indexes are now strict prefixes of a wider index
    # (follower_id also of the follower_id+followee_id unique), so they only
    # cost write amplification. The old release's queries plan onto the new
    # composites just as well, so dropping them in the same deploy is N-1 safe.
    drop_if_exists(
      index(:follows, [:followee_id], name: "follows_followee_id_index", concurrently: true)
    )

    drop_if_exists(
      index(:follows, [:follower_id], name: "follows_follower_id_index", concurrently: true)
    )
  end

  def down do
    create_if_not_exists(
      index(:follows, [:followee_id], name: "follows_followee_id_index", concurrently: true)
    )

    create_if_not_exists(
      index(:follows, [:follower_id], name: "follows_follower_id_index", concurrently: true)
    )

    drop_if_exists(
      index(:follows, ["followee_id", "inserted_at DESC", "id DESC"],
        name: "follows_followee_recency_index",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:follows, ["follower_id", "inserted_at DESC", "id DESC"],
        name: "follows_follower_recency_index",
        concurrently: true
      )
    )
  end
end
