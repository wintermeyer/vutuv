defmodule Vutuv.Repo.Migrations.CreateMembership do
  use Ecto.Migration

  def change do
    create table(:memberships) do
      add :connection_id, references(:connections, on_delete: :nothing)
      add :group_id, references(:groups, on_delete: :nothing)

      timestamps()
    end
    create index(:memberships, [:connection_id])
    create index(:memberships, [:group_id])

  end
end
