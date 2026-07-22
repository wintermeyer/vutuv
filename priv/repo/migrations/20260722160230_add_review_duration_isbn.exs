defmodule Vutuv.Repo.Migrations.AddReviewDurationIsbn do
  use Ecto.Migration

  # Which edition a stored running time belongs to: NULL means the review's
  # own ISBN (an exact answer), an ISBN means it was borrowed from another
  # audio edition of the same work and the card marks it approximate. A plain
  # addition the currently deployed release ignores.
  def change do
    alter table(:post_reviews) do
      add(:duration_isbn, :string)
    end
  end
end
