defmodule Vutuv.Repo.Migrations.AddBrokenToUrls do
  use Ecto.Migration

  def change do
    alter table(:urls) do
      add :broken, :boolean
    end
  end
end
