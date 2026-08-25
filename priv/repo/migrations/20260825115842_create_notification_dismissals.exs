defmodule Vutuv.Repo.Migrations.CreateNotificationDismissals do
  use Ecto.Migration

  # The per-event read exception behind `Vutuv.Activity.mark_notification_seen/3`
  # (`notification_post_reads` is its per-post sibling); that function's docs
  # carry the reasoning.
  #
  # `source_id` is the id of the row the feed derives the event from — a
  # follow, a like, an endorsement, an image scan — so it deliberately carries
  # no foreign key: it points at a different table per kind. Nothing breaks
  # when the source row is deleted; the event disappears with it and the
  # dismissal simply stops matching anything.
  #
  # Write-once, so no `updated_at`. The unique index serves all three readers:
  # the tally's per-kind subquery, the page's whole-member read, and the delete
  # `mark_notifications_read/1` runs once the marker covers them.
  def change do
    create table(:notification_dismissals) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:source_id, :binary_id, null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:notification_dismissals, [:user_id, :kind, :source_id]))
  end
end
