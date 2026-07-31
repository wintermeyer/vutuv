defmodule Vutuv.Repo.Migrations.CreateFediverseBookmarks do
  use Ecto.Migration

  @moduledoc """
  "Keep this for me" for anything that came from another network (issue #1276):
  a cached post by a followed account, or a reply that arrived under a vutuv
  post.

  **One table for both**, unlike the like and reshare markers beside it, which
  have one per subject. Those two had to be split: each is read by queries that
  join its own subject and its own audience rules, and the reshare is a feed
  source. A bookmark is none of that — it federates nothing, is addressed to
  nobody, carries no audience question, and is only ever read as "what did this
  member save", which wants the two kinds interleaved rather than apart. So it
  follows the `post_screenshots` pattern already in this schema: two nullable
  owner columns and a check constraint saying exactly one is set.

  Nothing here is public and nothing here is a count: a bookmark is private to
  the member who made it. The row cascades with our copy of what it points at
  (six-month retention), which is the honest behaviour — we cannot keep a
  pointer to something we no longer hold.
  """

  def change do
    create table(:fediverse_bookmarks) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all))
      add(:note_id, references(:fediverse_notes, on_delete: :delete_all))

      timestamps(updated_at: false)
    end

    create(
      constraint(:fediverse_bookmarks, :fediverse_bookmarks_one_subject,
        check: "(remote_post_id IS NOT NULL)::int + (note_id IS NOT NULL)::int = 1"
      )
    )

    # One bookmark per member and subject: one index per owner column, and
    # deliberately **not** partial (`where: "... IS NOT NULL"`). A partial unique
    # index cannot be inferred by `ON CONFLICT (user_id, note_id)` — Postgres
    # answers 42P10, "no unique or exclusion constraint matching the ON CONFLICT
    # specification" — and the whole marker fabric is built on that inference.
    #
    # Plain indexes are correct here anyway. A NULL is not equal to anything in
    # a btree, so the `note_id` index constrains nothing for a saved *post*
    # (whose `note_id` is NULL) — and it does not need to, because the
    # `remote_post_id` index constrains exactly those rows, and the check
    # constraint above guarantees every row has one owner or the other.
    create(unique_index(:fediverse_bookmarks, [:user_id, :remote_post_id]))
    create(unique_index(:fediverse_bookmarks, [:user_id, :note_id]))

    # The cascades' own indexes, so deleting a cached post or an expired reply
    # does not scan this table — both delete in bulk.
    create(index(:fediverse_bookmarks, [:remote_post_id]))
    create(index(:fediverse_bookmarks, [:note_id]))
    # The saved page's own read: "what I saved, newest first".
    create(index(:fediverse_bookmarks, [:user_id, :inserted_at]))
  end
end
