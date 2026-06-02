defmodule Vutuv.Repo.Migrations.CreateSearchQuery do
  use Ecto.Migration

  def change do
    create table(:search_queries) do
      add :value, :string
      add :is_email?, :boolean
      timestamps()
    end
    create index(:search_queries, [:value], unique: :true)
  end
end
