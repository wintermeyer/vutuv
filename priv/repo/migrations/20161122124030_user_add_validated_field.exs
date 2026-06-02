defmodule Vutuv.Repo.Migrations.UserAddValidatedField do
  use Ecto.Migration

  def change do
  	alter table (:users) do
      add :validated?, :boolean
    end
  end
end
