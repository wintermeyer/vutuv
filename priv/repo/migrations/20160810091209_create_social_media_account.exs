defmodule Vutuv.Repo.Migrations.CreateSocialMediaAccount do
  use Ecto.Migration

  def change do
    create table(:social_media_accounts) do
      add :user_id, references(:users)
    	add :provider, :string
    	add :account, :string
      timestamps()
    end

  end
end
