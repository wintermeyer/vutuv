defmodule Vutuv.Repo.Migrations.AddAdminField do
  use Ecto.Migration

  def change do
  	alter table(:users) do
  		add :administrator, :boolean, default: false
  	end
  end
end
