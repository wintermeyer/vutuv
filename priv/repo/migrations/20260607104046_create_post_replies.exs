defmodule Vutuv.Repo.Migrations.CreatePostReplies do
  use Ecto.Migration

  def change do
    # See create_posts: on the integer -> UUID upgrade path users.id/posts.id
    # are still bigint here (convert_ids_to_uuid_v7 runs later and converts
    # these too); a from-scratch build already has UUID ids. Match the live id
    # type or the FK creation fails on a uuid/bigint mismatch.
    legacy? = legacy_int_ids?()
    fk = if legacy?, do: :bigint, else: :binary_id
    table_opts = if legacy?, do: [primary_key: [name: :id, type: :bigserial]], else: []

    # A reply is a normal post plus this companion row naming its parent.
    # The row lives and dies with the reply (post_id cascades); the parent
    # references nilify instead, so a reply survives parent deletion and the
    # NULL pair encodes the banner state: both set → parent alive; only
    # parent_post_id NULL → post deleted but account alive ("a now-deleted
    # post by X"); both NULL → the account is gone too (account deletion
    # cascades through the author's posts), no name retained.
    create table(:post_replies, table_opts) do
      add(:post_id, references(:posts, type: fk, on_delete: :delete_all), null: false)
      add(:parent_post_id, references(:posts, type: fk, on_delete: :nilify_all))
      add(:parent_author_id, references(:users, type: fk, on_delete: :nilify_all))

      timestamps()
    end

    create(unique_index(:post_replies, [:post_id]))
    create(index(:post_replies, [:parent_post_id]))
    # Backs the derived "X replied to your post" notification feed.
    create(index(:post_replies, [:parent_author_id, :inserted_at]))
  end

  # True while the legacy integer ids are still in place (the upgrade path);
  # false on a from-scratch build where the repo's binary_id default already
  # made every id a UUID. Probing users.id is representative: every legacy
  # table is bigint until convert_ids_to_uuid_v7 converts them all at once.
  defp legacy_int_ids? do
    %{rows: [[type]]} =
      repo().query!(
        "SELECT data_type FROM information_schema.columns " <>
          "WHERE table_name = 'users' AND column_name = 'id'"
      )

    type == "bigint"
  end
end
