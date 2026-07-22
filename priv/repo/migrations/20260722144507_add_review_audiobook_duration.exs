defmodule Vutuv.Repo.Migrations.AddReviewAudiobookDuration do
  use Ecto.Migration

  # The running time of an audiobook review's edition, in whole minutes, read
  # from a library catalogue (Vutuv.AudiobookLength) with the other fetched
  # edition facts. A plain addition the currently deployed release ignores.
  def change do
    alter table(:post_reviews) do
      add(:duration_minutes, :integer)
    end
  end
end
