defmodule Vutuv.Repo.Migrations.CreateNotificationVisits do
  use Ecto.Migration

  # Every time a member looked at their notifications (the page, or the bell's
  # preview), so /notifications can draw each look as a line in the timeline
  # and travel back to one. `Vutuv.Activity.record_notification_visit/2` owns
  # the writes and prunes rows past the retention window as it goes.
  #
  # `at` is the moment of the look and moves forward when looks follow each
  # other within minutes (one sitting is one line), so it is not `inserted_at`.
  # A plain addition: the release still running during a deploy never reads it.
  def change do
    create table(:notification_visits) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:at, :utc_datetime, null: false)
      add(:source, :string, null: false, size: 16)
    end

    create(index(:notification_visits, [:user_id, :at]))
  end
end
