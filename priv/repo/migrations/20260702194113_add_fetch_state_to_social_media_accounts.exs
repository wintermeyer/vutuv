defmodule Vutuv.Repo.Migrations.AddFetchStateToSocialMediaAccounts do
  use Ecto.Migration

  def change do
    alter table(:social_media_accounts) do
      # Remote-fetch health for the inline Mastodon feed (only meaningful for
      # provider "Mastodon"). Consecutive failures walk an escalating backoff
      # ladder (15 min up to 48 h) via fetch_retry_at; after the ladder is
      # exhausted, or on a hard error (the account no longer exists),
      # fetch_disabled_at switches the account off for good. Editing the
      # handle resets all three. Persisted in the DB (not ETS) so backoff and
      # deactivation survive blue/green deploys. Additive columns with
      # defaults, N-1 safe.
      add(:fetch_failures, :integer, default: 0, null: false)
      add(:fetch_retry_at, :utc_datetime)
      add(:fetch_disabled_at, :utc_datetime)
    end
  end
end
