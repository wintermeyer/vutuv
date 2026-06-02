defmodule Vutuv.Repo.Migrations.CreateOAuthProvider do
  use Ecto.Migration

  def change do
    create table(:oauth_providers) do
      add :provider_id, :string
      add :provider, :string
      add :user_id, references(:users, on_delete: :nothing)
      timestamps()
    end
    create index(:oauth_providers, [:user_id, :provider], unique: true)
    create index(:oauth_providers, [:provider_id, :provider], unique: true)
  end

  def down do
    drop table(:oauth_providers)
  end
end
