defmodule Vutuv.Repo.Migrations.RenameDatesAndUrl do
  use Ecto.Migration

  def change do
  	rename table(:user_urls), to: table(:urls)
  	rename table(:user_dates), to: table(:dates)
  end

  def down do
  	rename table(:urls), to: table(:user_urls)
  	rename table(:dates), to: table(:user_dates)
  end
end
