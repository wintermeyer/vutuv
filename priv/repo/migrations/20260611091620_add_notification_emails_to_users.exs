defmodule Vutuv.Repo.Migrations.AddNotificationEmailsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Per-member switch for non-essential notification mail (today: the
      # unread-message nudge; future digests join it). Transactional mail
      # (login PINs, moderation notices) ignores it. Additive, N-1 safe.
      add(:notification_emails?, :boolean, default: true, null: false)
    end
  end
end
