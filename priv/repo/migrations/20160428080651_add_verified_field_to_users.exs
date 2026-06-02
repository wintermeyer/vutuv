defmodule Vutuv.Repo.Migrations.AddVerifiedFieldToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :verified, :boolean, default: false
    end
  end
end
