defmodule Vutuv.Repo.Migrations.AddEmailPublicField do
  use Ecto.Migration

  def change do
    alter table(:emails) do
      add :public?, :boolean
    end
  end
end
