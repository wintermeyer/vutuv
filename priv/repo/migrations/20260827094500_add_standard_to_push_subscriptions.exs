defmodule Vutuv.Repo.Migrations.AddStandardToPushSubscriptions do
  use Ecto.Migration

  # Mastodon's own default is false, and it has to be ours too: a client that
  # never sends the flag is a client that expects the legacy `aesgcm` body it
  # was written against, so a row that predates this column must read as
  # "legacy", not as "standard".
  def change do
    alter table(:mastodon_push_subscriptions) do
      add(:standard, :boolean, null: false, default: false)
    end
  end
end
