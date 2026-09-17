defmodule Vutuv.Repo.Migrations.AddReviewAndCountsToAds do
  use Ecto.Migration

  # An ad can now be turned down by an admin or withdrawn (by its booker while
  # it waits for approval, by an admin at any time before its day), and it
  # counts how often it was seen and clicked. Both kinds of ending free the
  # day, so the unique index on `day` covers only the bookings still standing.
  #
  # N-1: plain additions, and the replacement index keeps the name
  # `ads_day_index` the running release's `unique_constraint(:day)` matches.
  # That release never writes the new columns, so nothing it does can leave
  # two rows on one day; the ad system is off on production anyway. Rolling
  # back fails once a day holds a withdrawn and a standing booking.
  def change do
    alter table(:ads) do
      add(:rejected_at, :utc_datetime)
      add(:rejected_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      # What the booker is told; the changeset caps it at 2,000 characters.
      add(:rejection_reason, :text)
      add(:cancelled_at, :utc_datetime)
      add(:cancelled_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      # Cards seen and title links clicked, counted per ad and never per person.
      add(:views_count, :integer, null: false, default: 0)
      add(:clicks_count, :integer, null: false, default: 0)
    end

    drop(unique_index(:ads, [:day]))

    create(
      unique_index(:ads, [:day],
        name: :ads_day_index,
        where: "rejected_at IS NULL AND cancelled_at IS NULL"
      )
    )
  end
end
