defmodule Vutuv.Repo.Migrations.AddGranularEmailPrefsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Per-type switches for the new opt-in notification mails (connection
      # request / endorsement / new follower). The existing notification_emails?
      # column stays as the "unread messages" switch. These three default to
      # FALSE on purpose: turning them on would otherwise start mailing every
      # existing member on the next deploy without their say-so, so they are
      # opt-in. Additive nullable-with-default columns, N-1 safe: the currently
      # deployed release simply never reads them.
      add(:email_on_connection_request?, :boolean, default: false, null: false)
      add(:email_on_endorsement?, :boolean, default: false, null: false)
      add(:email_on_follower?, :boolean, default: false, null: false)
    end
  end
end
