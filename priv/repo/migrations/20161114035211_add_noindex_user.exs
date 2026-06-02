defmodule Vutuv.Repo.Migrations.AddNoindexUser do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :noindex?, :boolean, default: false
    end
  end
end
