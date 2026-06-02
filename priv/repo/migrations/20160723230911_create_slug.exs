defmodule Vutuv.Repo.Migrations.CreateSlug do
  use Ecto.Migration

  def change do
    create table(:slugs) do
    	add :value, :string, size: 32
    	add :user_id, references(:users)
      timestamps()
    end
    create unique_index(:slugs, [:value])
  end
end
