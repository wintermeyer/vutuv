defmodule Vutuv.Repo.Migrations.CreateDataEnrichment do
  use Ecto.Migration

  def change do
    create table(:data_enrichments) do
      add :user_id, :integer
      add :session_id, :integer
      add :description, :string
      add :value, :string
      add :source, :string

      timestamps()
    end

  end
end
