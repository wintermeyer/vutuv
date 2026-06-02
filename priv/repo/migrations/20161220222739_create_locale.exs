defmodule Vutuv.Repo.Migrations.CreateLocale do
  use Ecto.Migration

  def change do
    create table(:locales) do
      add :value, :string
      add :endonym, :string

      timestamps()
    end

  end
end
