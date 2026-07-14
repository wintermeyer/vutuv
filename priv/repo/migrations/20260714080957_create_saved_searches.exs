defmodule Vutuv.Repo.Migrations.CreateSavedSearches do
  use Ecto.Migration

  # Saved searches with e-mail alerts (issue #935, Jobs 8/9). Symmetric for both
  # sides of the market: a candidate saves a job-board search, a recruiter saves
  # a people search, and either can be nudged by mail when a new match appears.
  #
  # `query` is the exact URL query string of the board (`/jobs`) or people
  # (`/search`) page, so saving simply captures the current filters and the
  # sweeper re-runs the very same query. `last_notified_at` is the high-water
  # mark (same pattern as the DM notification cutoff): only entities newer than
  # it count, so a mail never repeats an old result.
  #
  # The user FK cascades on delete, so `Accounts.delete_user/1` needs no change
  # — the row goes with the account.
  def change do
    create table(:saved_searches, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :user_id,
        references(:users, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(:kind, :string, null: false)
      add(:query, :string, null: false)
      add(:notify, :string, null: false, default: "none")
      add(:last_run_at, :naive_datetime)
      add(:last_notified_at, :naive_datetime)

      timestamps()
    end

    # The sweeper walks a member's searches; the settings list shows a member's
    # own searches newest first.
    create(index(:saved_searches, [:user_id]))
    # The daily sweep selects every notifying search in one pass.
    create(index(:saved_searches, [:notify]))
  end
end
