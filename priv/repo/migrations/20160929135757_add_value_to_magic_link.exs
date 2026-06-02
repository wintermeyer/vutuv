defmodule Vutuv.Repo.Migrations.AddValueToMagicLink do
  use Ecto.Migration

  def change do
    alter table(:magic_links) do
      add :value, :string
    end
  end
end
