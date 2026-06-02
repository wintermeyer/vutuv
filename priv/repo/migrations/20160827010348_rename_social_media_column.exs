defmodule Vutuv.Repo.Migrations.RenameSocialMediaColumn do
  use Ecto.Migration

  def change do
  	alter table(:social_media_accounts) do
  		remove(:account)
  		add :value, :string
  	end
  end

  def down do
  	alter table(:social_media_accounts) do
  		remove(:value)
  		add :account, :string
  	end
  end
end
