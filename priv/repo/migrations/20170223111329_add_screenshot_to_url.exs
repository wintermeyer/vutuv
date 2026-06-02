defmodule Vutuv.Repo.Migrations.AddScreenshotToUrl do
  use Ecto.Migration

  def change do
    alter table(:urls) do
      add :screenshot, :string
    end
  end
end
