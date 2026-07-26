defmodule Vutuv.Repo.Migrations.CreateFediverseRevocationRecords do
  use Ecto.Migration

  # Issue #1102: a takedown here has to leave the building. Two plain additions.
  #
  # `fediverse_post_deliveries` is the address book a revocation needs: which
  # inbox received a post, and under which Note id. Without it a `Delete` can
  # only go to whoever follows the member *now* (a server that has since
  # unfollowed keeps its copy forever) and can only name the id built from the
  # *current* username (which stops matching after a rename).
  #
  # `fediverse_delivery_failures` is the ledger that keeps an incomplete takedown
  # from being silent: a `Delete` or `Flag` dropped after the last retry lands
  # here for the operator to see on /admin/fediverse.
  def change do
    create table(:fediverse_post_deliveries) do
      # No foreign key into `posts` on purpose: the revocation runs **after** the
      # post row is gone (see `Vutuv.Posts.delete_post/1`), so a cascade would
      # erase the addresses moments before they are needed. The rows are cleared
      # explicitly instead, by the revocation itself and by account deletion.
      add(:post_id, :binary_id, null: false)
      add(:user_id, :binary_id, null: false)
      # `:text`, like every other URI column here (`fediverse_followers.inbox_uri`,
      # `fediverse_notes.object_uri`): a remote server's inbox address is not ours
      # to bound, and a varchar(255) would raise 22001 on the publish path.
      add(:inbox_uri, :text, null: false)
      # The Note id this copy was published under, kept verbatim: it is what the
      # remote server stored, and a rename must not change what a Tombstone names.
      add(:object_uri, :text, null: false)

      timestamps(updated_at: false)
    end

    # One row per (post, inbox, published id). An `Update` after a rename
    # therefore adds a second id rather than overwriting the first, so both
    # copies can be revoked.
    #
    # Two `:text` columns in one btree index stay inside Postgres' ~2704-byte
    # index-entry limit because both sources cap a URI at 2048 bytes
    # (`Vutuv.Fediverse.Follower` / `.Note`) and the published id is our own
    # short URL. Raising either cap means revisiting this index.
    create(
      unique_index(:fediverse_post_deliveries, [:post_id, :inbox_uri, :object_uri],
        name: :fediverse_post_deliveries_target_index
      )
    )

    create(index(:fediverse_post_deliveries, [:user_id]))

    create table(:fediverse_delivery_failures) do
      add(:activity_type, :string, null: false)
      add(:host, :string, null: false)
      # A Flag names the *remote* note it reports, so this is not always one of
      # our own bounded URLs either.
      add(:object_uri, :text)
      # A plain value, not an association, like the other audit ledgers: the row
      # must stay readable after the account it names is gone.
      add(:user_id, :binary_id)
      add(:attempts, :integer, null: false)
      add(:last_error, :string)

      timestamps(updated_at: false)
    end

    create(index(:fediverse_delivery_failures, [:inserted_at]))
  end
end
