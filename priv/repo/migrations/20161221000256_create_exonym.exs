defmodule Vutuv.Repo.Migrations.CreateExonym do
  use Ecto.Migration

  def change do
    create table(:exonyms) do
      add :value, :string
      
      add :locale_id, references(:locales)
      add :exonym_locale_id, references(:locales)

      timestamps()
    end

  end
end
