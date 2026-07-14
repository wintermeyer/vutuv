defmodule Vutuv.Repo.Migrations.AddSavedSearchFieldsToUsers do
  use Ecto.Migration

  # Two columns for saved-search alerts (issue #935):
  #
  #   * saved_search_emails? — the member-level opt-out that the alert mail's
  #     one-click List-Unsubscribe flips (like the other notification prefs);
  #     default true, so existing members keep getting the alerts they enable.
  #
  #   * employment_status_set_at — when the member last changed their
  #     job-availability status (#928). It is the freshness signal for people
  #     alerts: a saved recruiter search surfaces a member who newly became
  #     "open"/"looking" since the last mail, not only brand-new registrations.
  #
  # Both are plain nullable/defaulted additions, so the migration is N-1
  # backward-compatible (the previous release ignores the columns).
  def change do
    alter table(:users) do
      add(:saved_search_emails?, :boolean, null: false, default: true)
      add(:employment_status_set_at, :naive_datetime)
    end
  end
end
