defmodule Vutuv.Repo.Migrations.AddEmploymentStatusVisibilityToUsers do
  use Ecto.Migration

  # Who may see the member's job-availability badge (issue #928):
  # "everyone" (all visitors, incl. logged-out + crawlers), "members" (only
  # signed-in members — the safe default), "hidden" (nobody; the setting is
  # kept but shows to no one). A NOT NULL column with a "members" default, so
  # Postgres backfills every existing row to the safe default in one step and
  # the currently deployed release (which never writes this column) keeps
  # inserting valid rows — an N-1-compatible plain add.
  def change do
    alter table(:users) do
      add :employment_status_visibility, :string, null: false, default: "members"
    end
  end
end
