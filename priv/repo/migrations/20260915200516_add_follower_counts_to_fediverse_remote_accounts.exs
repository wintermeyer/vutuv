defmodule Vutuv.Repo.Migrations.AddFollowerCountsToFediverseRemoteAccounts do
  use Ecto.Migration

  def change do
    alter table(:fediverse_remote_accounts) do
      # Public audience metadata used to estimate a reposter's possible reach.
      # The collection URL comes from the verified actor document. Counts are a
      # timestamped cache because remote servers may refuse or change them.
      add(:followers_uri, :text)
      add(:follower_count, :bigint)
      add(:follower_count_checked_at, :utc_datetime)
    end
  end
end
