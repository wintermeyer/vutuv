defmodule Vutuv.Repo.Migrations.CreateSearchTerm do
  use Ecto.Migration

  def change do
    create table(:search_terms) do
    	add :value, :string
    	add :score, :integer
    	add :user_id, references(:users, on_delete: :nothing)
      timestamps()
    end

  end
end
