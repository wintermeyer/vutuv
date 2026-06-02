defmodule Vutuv.Repo.Migrations.MakeEmailUniqueField do
  use Ecto.Migration

  def change do
  	create unique_index(:emails, [:value])
  end
end
