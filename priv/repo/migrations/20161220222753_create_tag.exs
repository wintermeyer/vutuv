defmodule Vutuv.Repo.Migrations.CreateTag do
  use Ecto.Migration

  def change do
    create table(:tags) do
      add :slug, :string

      timestamps()
    end
  	create unique_index(:tags, [:slug], unique: true)
  end
end
