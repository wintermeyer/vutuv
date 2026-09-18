defmodule Vutuv.Repo.Migrations.AddGroupIdToAds do
  use Ecto.Migration

  # A week or a month is still one row per day - the unique index on `day`,
  # `current_banner/0`, the sightings and the counters all stay as they are -
  # and the rows of one purchase share a `group_id` so the review, the
  # cancellation and "My bookings" can treat them as the one thing that was
  # bought. A plain addition, so the release still serving traffic during the
  # blue/green switch keeps working: it never writes the column, and a single
  # day booked by it simply has none.
  def change do
    alter table(:ads) do
      add(:group_id, :binary_id)
    end

    create(index(:ads, [:group_id]))
  end
end
