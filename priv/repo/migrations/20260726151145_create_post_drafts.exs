defmodule Vutuv.Repo.Migrations.CreatePostDrafts do
  @moduledoc """
  The composer keeps what you typed (issue #1148 follow-up).

  A page reload used to empty the composer: LiveView's form recovery only runs
  on a socket *reconnect*, and a reload builds the page from scratch. So the
  composer now writes its content here as you type and reads it back when it
  opens.

  **One row per composer context**, which is what the three partial unique
  indexes below enforce: a member has at most one new-post draft, at most one
  draft per post they are answering, and at most one per remote reply they are
  answering. Postgres treats NULLs in a unique index as distinct, so a plain
  `unique_index(:post_drafts, [:user_id, :parent_id])` would happily let a
  member collect an unlimited pile of new-post drafts — hence the `IS NULL` /
  `IS NOT NULL` split rather than one index.

  Both context columns cascade, so answering a post that is later deleted takes
  the abandoned draft with it rather than leaving a row pointing nowhere. The
  same goes for the account itself, which is why `Vutuv.Accounts.delete_user/1`
  needs no new step: there is no file behind a draft, only the row.

  `image_ids` is an array rather than a join table because the order **is** the
  layout — the first photo leads the mosaic — and an array preserves it for
  free. The ids point at still-pending `post_images` rows, which is why
  `Vutuv.Posts.sweep_pending_images/1` now spares anything a draft still names.

  N-1 safe: a new table nothing in the running release reads or writes.
  """

  use Ecto.Migration

  def change do
    create table(:post_drafts) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      # The composer context. Both nil = the feed's new-post composer.
      add(:parent_id, references(:posts, on_delete: :delete_all))
      add(:remote_note_id, references(:fediverse_notes, on_delete: :delete_all))

      # Text rather than varchar(255): a draft body runs to the post limit
      # (20k chars), and the tag line is raw, unparsed input a paste can make
      # arbitrarily long. A 22001 here would abort a background write the
      # member never asked for.
      add(:body, :text, null: false, default: "")
      add(:tags, :text, null: false, default: "")
      add(:mode, :string, null: false, default: "text")
      add(:license, :string)
      add(:review, :map, null: false, default: %{})
      add(:image_ids, {:array, :binary_id}, null: false, default: [])

      # The per-photo panel (alt text, caption, the camera/download switches),
      # keyed by image id. It lives in the composer's socket until save, so
      # without it here a restored draft would hand the photos back stripped of
      # the descriptions the member had already written for them.
      add(:photos, :map, null: false, default: %{})

      timestamps()
    end

    create(
      unique_index(:post_drafts, [:user_id],
        where: "parent_id IS NULL AND remote_note_id IS NULL",
        name: :post_drafts_user_new_post_index
      )
    )

    create(
      unique_index(:post_drafts, [:user_id, :parent_id],
        where: "parent_id IS NOT NULL",
        name: :post_drafts_user_parent_index
      )
    )

    create(
      unique_index(:post_drafts, [:user_id, :remote_note_id],
        where: "remote_note_id IS NOT NULL",
        name: :post_drafts_user_remote_note_index
      )
    )

    # The sweeper's "what has been abandoned" query.
    create(index(:post_drafts, [:updated_at]))
  end
end
