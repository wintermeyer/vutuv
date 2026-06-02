defmodule Vutuv.Repo.Migrations.CreateAddress do
  use Ecto.Migration

  def change do
    create table(:addresses) do
      add :user_id, references(:users)
    	add :description, :string
    	add :line_1, :string
    	add :line_2, :string
    	add :zip_code, :string
    	add :city, :string
    	add :state, :string
    	add :country, :string
      timestamps()
    end

  end
end
