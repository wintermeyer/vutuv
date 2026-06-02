defmodule Vutuv.Repo.Migrations.AddBirthdayReminderSettingToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :send_birthday_reminder, :boolean, default: true
    end
  end
end
