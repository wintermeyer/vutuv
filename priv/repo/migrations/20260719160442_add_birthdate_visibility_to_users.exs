defmodule Vutuv.Repo.Migrations.AddBirthdateVisibilityToUsers do
  use Ecto.Migration

  # How much of a member's birthday the public profile (and its agent-format
  # siblings) reveal: "full" (date + age, the historical behaviour), "age"
  # (age only), "day_month" (day and month, no year) or "hidden" (stored but
  # never shown publicly). A plain additive column with a NOT NULL default, so
  # it is N-1 safe: the currently deployed release, which doesn't know the
  # column, keeps inserting without it and the default backfills. Defaulting to
  # "full" keeps every existing member's birthday exactly as public as it is
  # today — more privacy is opt-in.
  def change do
    alter table(:users) do
      add(:birthdate_visibility, :string, null: false, default: "full")
    end
  end
end
