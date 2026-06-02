defmodule Vutuv.Repo.Migrations.NullifyDefaultDates do
  use Ecto.Migration

  def change do
  	execute("UPDATE users SET birthdate = NULL WHERE birthdate = '1900-01-01'")
  end
end
