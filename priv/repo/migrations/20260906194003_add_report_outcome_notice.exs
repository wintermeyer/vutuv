defmodule Vutuv.Repo.Migrations.AddReportOutcomeNotice do
  use Ecto.Migration

  # Two plain nullable columns, so the currently deployed release keeps working
  # untouched (N-1): it writes neither and reads neither. What they are for is
  # in `Vutuv.Moderation.Notifier.reporters_case_closed/1` (issue #2011).
  def change do
    alter table(:moderation_reports) do
      add(:outcome_notified_at, :naive_datetime)
      add(:reporter_locale, :string, size: 8)
    end
  end
end
