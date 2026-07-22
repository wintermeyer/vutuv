defmodule Vutuv.Repo.Migrations.CreatePostReviews do
  use Ecto.Migration

  # The structured review sidecar of a post (book/film reviews): kind +
  # identifier (ISBN-13 / IMDb id) + cached display metadata + the fetched
  # cover image state. One review per post; plain addition, N-1 safe.
  def change do
    create table(:post_reviews) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:identifier, :string)
      add(:title, :string, null: false)
      add(:creator, :string)
      add(:year, :integer)
      # How the reviewer consumed the work (book: print/ebook/audiobook,
      # movie: cinema/streaming/disc); nil = unspecified.
      add(:medium, :string)
      add(:cover, :string)
      add(:cover_status, :string, null: false, default: "none")
      add(:cover_moderation, :string)

      timestamps()
    end

    create(unique_index(:post_reviews, [:post_id]))
  end
end
