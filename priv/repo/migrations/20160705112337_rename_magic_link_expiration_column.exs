defmodule Vutuv.Repo.Migrations.RenameMagicLinkExpirationColumn do
  use Ecto.Migration

  def change do
  	alter table (:users) do
  		remove :magic_link_expiration
  		add :magic_link_created_at, :naive_datetime
  	end
  end
end
