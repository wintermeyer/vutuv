defmodule Vutuv.Repo.Migrations.CreateUserDate do
  use Ecto.Migration

  def change do
    create table(:user_dates) do
  		add :user_id, references(:users)

  		add :value, :date
  		add :description, :string

  		timestamps()
  	end

  end
end
