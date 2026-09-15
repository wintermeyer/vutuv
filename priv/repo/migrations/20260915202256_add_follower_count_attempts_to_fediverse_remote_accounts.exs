defmodule Vutuv.Repo.Migrations.AddFollowerCountAttemptsToFediverseRemoteAccounts do
  use Ecto.Migration

  def change do
    alter table(:fediverse_remote_accounts) do
      # Separate failed attempts from successful observations. Otherwise a
      # refusal would make an old number appear freshly verified.
      add(:follower_count_attempted_at, :utc_datetime)
    end
  end
end
