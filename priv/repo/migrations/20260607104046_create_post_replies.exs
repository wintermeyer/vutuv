defmodule Vutuv.Repo.Migrations.CreatePostReplies do
  use Ecto.Migration

  def change do
    # A reply is a normal post plus this companion row naming its parent.
    # The row lives and dies with the reply (post_id cascades); the parent
    # references nilify instead, so a reply survives parent deletion and the
    # NULL pair encodes the banner state: both set → parent alive; only
    # parent_post_id NULL → post deleted but account alive ("a now-deleted
    # post by X"); both NULL → the account is gone too (account deletion
    # cascades through the author's posts), no name retained.
    create table(:post_replies) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:parent_post_id, references(:posts, on_delete: :nilify_all))
      add(:parent_author_id, references(:users, on_delete: :nilify_all))

      timestamps()
    end

    create(unique_index(:post_replies, [:post_id]))
    create(index(:post_replies, [:parent_post_id]))
    # Backs the derived "X replied to your post" notification feed.
    create(index(:post_replies, [:parent_author_id, :inserted_at]))
  end
end
