defmodule Vutuv.Repo.Migrations.CreateFediverseNoteLikes do
  use Ecto.Migration

  @moduledoc """
  A member's like of a **reply** that arrived from another network under a vutuv
  post (issue #1270) — the sibling of `fediverse_post_likes`, one table further
  down the conversation.

  Same rules as that table, for the same reasons: the row is the local marker
  and the `Like` delivered to the author's own inbox is what their server
  counts; there is no count column, because vutuv cannot know a reply's real
  tally and a figure assembled from the likes that happened to pass through this
  installation would read as the real one while being a fraction of it; and the
  row cascades away with the cached reply, whose retention is six months,
  without anything being lost — a re-like afterwards sends a duplicate every
  implementation treats as a no-op.
  """

  def change do
    create table(:fediverse_note_likes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:note_id, references(:fediverse_notes, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    # The pair is the identity: liking twice is the same like. It also serves
    # the per-member lookup the conversation batches ("which of the replies on
    # this page do I already like"), left-most column first.
    create(unique_index(:fediverse_note_likes, [:user_id, :note_id]))
    # The cascade's own index: without it every note delete sequentially scans
    # this table, and the sweeper deletes expired notes in bulk.
    create(index(:fediverse_note_likes, [:note_id]))
  end
end
