defmodule Vutuv.Repo.Migrations.DropUsersSendBirthdayReminder do
  use Ecto.Migration

  # Added in 2017 for a birthday-reminder feature that never shipped; the
  # column is not in the Ecto schema and nothing reads or writes it.
  def up do
    alter table(:users) do
      remove(:send_birthday_reminder)
    end
  end

  def down do
    alter table(:users) do
      add(:send_birthday_reminder, :boolean, default: true)
    end
  end
end
