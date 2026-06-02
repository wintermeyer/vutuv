defmodule Vutuv.Repo.Migrations.SetAllBirthdayRemindersToTrue do
  use Ecto.Migration

  def up do
    execute "UPDATE users SET send_birthday_reminder = true"
  end

  def down do
  end
end
