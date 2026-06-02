defmodule Vutuv.Repo.Migrations.AddLocaleUniqueIndexes do
  use Ecto.Migration

  def change do
  	create unique_index(:locales, [:value], unique: true)
  	create unique_index(:exonyms, [:value, :locale_id], unique: true)
  end
end
