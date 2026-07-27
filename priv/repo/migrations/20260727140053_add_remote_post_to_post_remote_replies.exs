defmodule Vutuv.Repo.Migrations.AddRemotePostToPostRemoteReplies do
  use Ecto.Migration

  @moduledoc """
  The sidecar generalizes: a vutuv post can now answer either a reply that
  arrived under one of the member's own posts (issue #1070, `note_id`) or a post
  by an account they follow (issue #1165, `remote_post_id`).

  Two nullable columns rather than one polymorphic pair, because the two targets
  are different tables with different lifetimes and a `{type, id}` column would
  buy nothing but a lost foreign key. Exactly one is set; everything delivery
  needs was already copied onto the row itself at creation time, so a null here
  costs nothing.

  `nilify_all`, like `note_id`: both targets are six-month caches, and the
  member's own answer must outlive the copy of what it answered — deleting the
  cached post must never delete somebody's post.
  """

  def change do
    alter table(:post_remote_replies) do
      add(:remote_post_id, references(:fediverse_posts, on_delete: :nilify_all))
    end

    # The cascade's own index: without it every cached-post delete sequentially
    # scans this table, and expiry deletes in bulk.
    create(index(:post_remote_replies, [:remote_post_id]))
  end
end
