defmodule Vutuv.Repo.Migrations.CreateTagTrendVerdicts do
  use Ecto.Migration

  # What the trending pass last learned about each candidate, and when (see
  # `Vutuv.Tags.TrendVerdict`). A table of its own rather than more rows in
  # `tag_trends`: the release now serving traffic reads every row of that table
  # as an offer, so a dropped bot wave stored there would be offered by it
  # during a deploy. A plain addition, N-1 safe, and no `tag_id` — a trending
  # name may name no topic here at all.
  def change do
    create table(:tag_trend_verdicts) do
      # The candidate's name folded to lower case, the key a pass groups the
      # servers' answers by. Bounded like `tag_trends.name`.
      add(:name, :string, null: false)

      # `passed`, `dropped` or `failed`.
      add(:outcome, :string, null: false)

      # The sample the verdict was taken on, nil when the census failed.
      add(:author_hosts, :integer)
      add(:bot_posts, :integer)
      add(:sampled, :integer)

      # The clock the census orders by, stamped on every outcome.
      add(:vetted_at, :utc_datetime, null: false)

      timestamps()
    end

    create(unique_index(:tag_trend_verdicts, [:name]))
  end
end
