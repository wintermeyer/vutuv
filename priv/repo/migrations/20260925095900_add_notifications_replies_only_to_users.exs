defmodule Vutuv.Repo.Migrations.AddNotificationsRepliesOnlyToUsers do
  use Ecto.Migration

  # The "Only replies and mentions" switch on /notifications, kept with the
  # member so it survives the next visit and holds on every device. A plain
  # additive column with a default, so the running release is unaffected.
  def change do
    alter table(:users) do
      add(:notifications_replies_only?, :boolean, null: false, default: false)
    end
  end
end
