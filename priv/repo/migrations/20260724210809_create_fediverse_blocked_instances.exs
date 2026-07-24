defmodule Vutuv.Repo.Migrations.CreateFediverseBlockedInstances do
  use Ecto.Migration

  # The operator's kill switch per remote server (issue #1067). Anyone can run
  # an ActivityPub server, so "a server we federate with" is not a vetted party;
  # before vutuv stores anything a remote sends us, the operator needs a way to
  # shut one out. Per-installation content, so it is data plus an admin screen
  # (/admin/fediverse), never a source edit.
  #
  # New table, plain addition -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_blocked_instances) do
      # The bare, lowercased hostname ("mastodon.example"), never a URL: the
      # inbox compares it against the host of the sender's actor id.
      add(:host, :string, null: false)
      # Free-text note for the next operator ("spam wave 2026-07"), optional.
      add(:reason, :string)
      # Who blocked it. The row outlives the admin account (nilify), because a
      # block must not lapse just because the admin who set it left.
      add(:blocked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps()
    end

    # One row per host; re-blocking is a no-op, not a duplicate. Also the index
    # the inbox's per-request "is this host blocked?" lookup reads.
    create(unique_index(:fediverse_blocked_instances, [:host]))
  end
end
