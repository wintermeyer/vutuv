defmodule Vutuv.Repo.Migrations.CreateUserUrl do
  use Ecto.Migration

  def change do
    create table(:user_urls) do
  		add :user_id, references(:users)

  		add :value, :string
  		add :description, :string

  		timestamps()
  	end

  end
end
