defmodule Vutuv.Repo.Migrations.DeleteDateAddBirthday do
  use Ecto.Migration

  def change do
  	drop table(:dates)
  end

  def down do
  	create table(:dates) do
  		add :user_id, references(:users)

  		add :value, :date
  		add :description, :string

  		timestamps()
  	end
  end
end
