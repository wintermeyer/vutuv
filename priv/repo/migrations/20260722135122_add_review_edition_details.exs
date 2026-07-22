defmodule Vutuv.Repo.Migrations.AddReviewEditionDetails do
  use Ecto.Migration

  # The two edition facts the book review card was missing: how many pages
  # this edition has and who published it. Both are fetched from Open Library
  # alongside the cover (never cast from params), so this is a plain addition
  # the currently deployed release simply ignores.
  def change do
    alter table(:post_reviews) do
      add(:pages, :integer)
      add(:publisher, :string)
    end
  end
end
