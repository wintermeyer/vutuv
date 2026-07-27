defmodule Vutuv.Repo.Migrations.CreateFediversePostLikes do
  use Ecto.Migration

  @moduledoc """
  A member's like of a post from an account they follow on another network
  (issue #1164).

  One row per member and remote post, and the row is only ever the **local
  marker**: the `Like` activity we deliver is what the author's own server
  counts, and it stands whatever happens here. That is why the row may cascade
  away with the cached post (retention, an upstream `Delete`, an instance
  block) without anything being lost — a re-like after expiry sends a duplicate
  the other side treats as a no-op.

  There is deliberately no count column and no count anywhere: vutuv does not
  know how many people liked a post on somebody else's server, and inventing a
  number out of the handful of likes that happened to pass through here would
  be a lie in the shape of a fact. The heart shows the member's own state.
  """

  def change do
    create table(:fediverse_post_likes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    # The pair is the identity: liking twice is the same like. It also serves
    # the per-member lookup the feed batches ("which of these 30 posts do I
    # already like"), left-most column first.
    create(unique_index(:fediverse_post_likes, [:user_id, :remote_post_id]))
    # The cascade's own index: without it every cached-post delete sequentially
    # scans this table, and expiry deletes in bulk.
    create(index(:fediverse_post_likes, [:remote_post_id]))
  end
end
