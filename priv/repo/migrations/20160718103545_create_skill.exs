defmodule Vutuv.Repo.Migrations.CreateSkill do
  use Ecto.Migration

  def change do
    create table(:skills) do
      add :name, :string
      add :downcase_name, :string
      add :slug, :string
      add :description, :string
      add :url, :string

      timestamps()
    end

  end
end
