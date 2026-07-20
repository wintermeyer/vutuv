defmodule Vutuv.Repo.Migrations.CreateTagFollows do
  use Ecto.Migration

  # Following a tag (issue #872). A private subscription that pulls a topic's
  # posts into your `/feed` — the topic-shaped twin of following a person
  # (`follows`), but silent: a tag has no owner to notify. `Vutuv.Tags` owns the
  # relation; `Vutuv.Posts.feed_page/2` reads it as a third feed source.
  #
  # Both FKs cascade on delete, so neither `Accounts.delete_user/1` nor tag
  # deletion needs a change — the row goes with whichever end disappears. Plain
  # additive table, so the migration is N-1 (blue/green) safe.
  def change do
    create table(:tag_follows, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :user_id,
        references(:users, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(
        :tag_id,
        references(:tags, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      timestamps()
    end

    # One follow per (member, tag); the leading user_id also serves the "tags I
    # follow" list, so no separate user_id index is needed.
    create(unique_index(:tag_follows, [:user_id, :tag_id]))
    # The reverse lookup: how many members follow a tag (the tag page's count).
    create(index(:tag_follows, [:tag_id]))
  end
end
