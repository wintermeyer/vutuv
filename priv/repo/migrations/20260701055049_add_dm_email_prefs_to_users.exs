defmodule Vutuv.Repo.Migrations.AddDmEmailPrefsToUsers do
  use Ecto.Migration

  # Per-member control over the unread-message notification email
  # (Vutuv.Chat.send_unread_notifications/0). Defaults reproduce the previous
  # hard-coded behaviour exactly: one email per unread burst (each_message?
  # false), sent once a message has been unread for 15 minutes. Plain additive
  # columns with constant defaults (metadata-only on modern Postgres), so the
  # currently deployed release keeps working while this runs — N-1 safe.
  def change do
    alter table(:users) do
      add(:dm_email_each_message?, :boolean, default: false, null: false)
      add(:dm_email_delay_minutes, :integer, default: 15, null: false)
    end
  end
end
