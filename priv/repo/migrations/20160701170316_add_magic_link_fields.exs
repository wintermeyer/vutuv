defmodule Vutuv.Repo.Migrations.AddMagicLinkFields do
  use Ecto.Migration

  def change do
  	alter table(:users) do
  		add :magic_link, :string
  		add :magic_link_expiration, :naive_datetime
  	end
  end
end
