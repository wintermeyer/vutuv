defmodule Vutuv.Repo.Migrations.CreateFediverseRemoteAccounts do
  use Ecto.Migration

  # Accounts on other networks that somebody here follows, and the follow itself
  # (issue #1160). Until now federation was outbound only: a fetched remote actor
  # document was read for its key and its inbox and then discarded, because
  # nothing here needed to remember who the other side was. A member following
  # somebody out there needs exactly that memory.
  #
  # Two tables rather than one, because they answer different questions and have
  # different lifetimes: the **account** is one row per remote actor however many
  # members follow it (so a re-sync, a block purge and later its cached posts all
  # have one place to hang off), the **follow** is the per-member relationship,
  # its handshake state and its mute flag.
  #
  # New tables only -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_remote_accounts) do
      # The actor's own AP id, the canonical identity. `text` like every other
      # remote URI column here (a remote id is not ours to bound), capped in
      # BYTES by the schema because of the btree unique index below.
      add(:actor_uri, :text, null: false)
      # The server it lives on, denormalized out of actor_uri: the following
      # browser's Server column, its filter, and the instance-block purge all
      # read it, and none of them should re-parse a URI in SQL.
      add(:host, :string, null: false)

      # Cosmetic, remote-supplied and hostile: capped at the usual varchar(255).
      add(:handle, :string)
      add(:name, :string)
      # The account's self-description, as plain text (never HTML — nothing a
      # stranger wrote is rendered raw). `text` with a generous schema cap, per
      # the varchar rule.
      add(:summary, :text)

      # Where activities for this account go, and the key its own deliveries are
      # verified against. All text: a remote server's addresses are not ours to
      # bound (the same reasoning as fediverse_followers.inbox_uri).
      add(:inbox_uri, :text, null: false)
      add(:shared_inbox_uri, :text)
      add(:public_key_id, :text)
      add(:public_key_pem, :text)

      # When the actor document was last read. The `Update` a remote broadcasts
      # keeps it current; a later refresh sweep schedules from it.
      add(:refreshed_at, :utc_datetime)

      timestamps()
    end

    # One row per remote actor: resolving a handle upserts, and an inbound
    # Update/Delete of that actor finds its row here. The schema bounds
    # actor_uri at 2048 bytes, well under the ~2704-byte btree key limit.
    create(unique_index(:fediverse_remote_accounts, [:actor_uri]))
    # The instance-block purge and the admin's per-host volume list.
    create(index(:fediverse_remote_accounts, [:host]))

    create table(:fediverse_follows) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :remote_account_id,
        references(:fediverse_remote_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # requested | accepted. A `Reject` deletes the row rather than storing a
      # third state: there is nothing left to show and nothing to retry, and
      # keeping a stranger's refusal on file earns nothing.
      add(:state, :string, null: false, default: "requested")
      # The id of the Follow activity we sent. An `Accept` or `Reject` names it,
      # which is how the answer finds the row it belongs to. `text` for the same
      # reason as the URIs; unique, so one server's answer can never seal
      # another member's follow.
      add(:follow_activity_id, :text, null: false)
      # The same meaning a local follow's mute has: the relationship stays, the
      # posts leave the feed.
      add(:muted, :boolean, null: false, default: false)

      timestamps()
    end

    create(unique_index(:fediverse_follows, [:user_id, :remote_account_id]))
    create(unique_index(:fediverse_follows, [:follow_activity_id]))
    # The inbound side reads "who here follows this account" on every activity
    # that arrives from it.
    create(index(:fediverse_follows, [:remote_account_id]))
  end
end
