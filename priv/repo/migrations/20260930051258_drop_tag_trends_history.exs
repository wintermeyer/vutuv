defmodule Vutuv.Repo.Migrations.DropTagTrendsHistory do
  use Ecto.Migration

  # Contract step after 20260929205905: the release before this one no longer
  # names the column, so it can go.
  def change do
    alter table(:tag_trends) do
      remove(:history, {:array, :bigint}, null: false, default: [])
    end
  end
end
