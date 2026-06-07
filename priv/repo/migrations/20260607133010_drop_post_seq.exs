defmodule Vutuv.Repo.Migrations.DropPostSeq do
  use Ecto.Migration

  def change do
    # The permalink is the post id (UUID v7) now; the per-author-per-day
    # counter and its uniqueness guarantee have no callers left.
    drop(unique_index(:posts, [:user_id, :published_on, :seq]))

    alter table(:posts) do
      remove(:seq, :integer, null: false)
    end

    # The year/month/day archive pages still filter by author + publication
    # date — the dropped unique index used to cover that.
    create(index(:posts, [:user_id, :published_on]))
  end
end
