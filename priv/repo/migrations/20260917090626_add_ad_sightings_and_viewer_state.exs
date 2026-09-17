defmodule Vutuv.Repo.Migrations.AddAdSightingsAndViewerState do
  use Ecto.Migration

  # Plain additions (a new table and two nullable columns), so this is N-1
  # compatible in one deploy: the running release reads neither.
  def change do
    # Which booked ad a member has seen, and when: the history behind "seen
    # ads" and the per-ad reach. One row per member and ad, counted up on
    # every further sighting. The house ad has no row to point at and leaves
    # none.
    create table(:ad_sightings) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:ad_id, references(:ads, type: :binary_id, on_delete: :delete_all), null: false)
      add(:first_seen_at, :utc_datetime, null: false)
      add(:last_seen_at, :utc_datetime, null: false)
      add(:times_seen, :integer, null: false, default: 1)
    end

    # The upsert's conflict target, and the lookup by member: one ad a day and
    # 90 days kept leave a member with a few dozen rows, so their history sorts
    # by `last_seen_at` without an index of its own. Leaving that column out of
    # every index keeps the repeat sighting's update a HOT one.
    create(unique_index(:ad_sightings, [:user_id, :ad_id]))
    # Per-ad reach, and the retention sweep, which finds old rows by their ad.
    create(index(:ad_sightings, [:ad_id]))

    alter table(:users) do
      # The per-member frequency rules, kept on the server so they hold on
      # every device: when this member last saw an ad (house ad included),
      # and the Berlin day on which they closed one with its ✕.
      add(:ad_seen_at, :utc_datetime)
      add(:ads_dismissed_on, :date)
    end
  end
end
