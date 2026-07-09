defmodule Vutuv.Repo.Migrations.AddCodeStatsToSocialMediaAccounts do
  use Ecto.Migration

  # The cached public code-forge statistics (issue #922): a snapshot map per
  # GitHub/GitLab/Codeberg account plus its fetch time (refreshed when a
  # profile view finds it older than 7 days), and the member's opt-out toggle.
  # Plain additions, N-1 compatible in one deploy.
  def change do
    alter table(:social_media_accounts) do
      add(:code_stats, :map)
      add(:code_stats_fetched_at, :utc_datetime)
    end

    alter table(:users) do
      add(:show_code_stats?, :boolean, default: true, null: false)
    end
  end
end
