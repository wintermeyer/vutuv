defmodule Vutuv.Repo.Migrations.UserAddHeadline do
  use Ecto.Migration

  def change do
    alter table (:users) do
      add :headline, :string
    end
  end
end
