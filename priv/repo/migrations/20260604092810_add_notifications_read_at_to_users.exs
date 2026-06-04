defmodule Vutuv.Repo.Migrations.AddNotificationsReadAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Read marker for the in-app notifications page: the feed itself is
      # derived from connections / user_tag_endorsements at read time, so the
      # only state notifications need is "when did the user last look".
      # NULL means "never read" - every event counts as unread.
      add(:notifications_read_at, :naive_datetime)
    end
  end
end
