defmodule Vutuv.Repo.Migrations.DefaultTagTrendsHistoryToEmpty do
  use Ecto.Migration

  # Expand step of dropping `tag_trends.history`: the pill no longer draws the
  # week, so the code stops writing it and the column falls back to an empty
  # array. It stays NOT NULL for the previous release, which still writes it and
  # reads `[]` as a quiet week. A later deploy drops the column.
  def change do
    alter table(:tag_trends) do
      modify(:history, {:array, :bigint}, default: [], from: {{:array, :bigint}, default: nil})
    end
  end
end
