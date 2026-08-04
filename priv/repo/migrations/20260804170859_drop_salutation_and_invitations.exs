defmodule Vutuv.Repo.Migrations.DropSalutationAndInvitations do
  @moduledoc """
  Contract half of two removals whose code halves shipped in v7.230.0.

  **This must not ship with the release that removed the code.** Deploys are
  blue/green: migrations run while the *previous* release is still serving
  traffic, and that release's `Vutuv.Accounts.User` schema still lists
  `salutation`, so dropping the column underneath it breaks every query that
  loads a member — a login, a profile, the feed. Ship v7.230.0 first, confirm it
  is serving, then this. v7.230.0 was deployed and confirmed serving
  before this branch was cut.

  `users.salutation` said how a member wanted to be addressed in a letter and
  drove the German email greeting. `users.gender` drives that greeting now
  (`UserHelpers.email_greeting/1`), seeded from this very column by
  `20260804152553`, so nothing is lost by dropping it: every `mr` became `male`
  and every `ms` became `female` before this runs.

  The `invitations` table backed "invite a friend": a hashed once-per-address
  record, a prefilled sign-up link and an auto-follow on acceptance. The feature
  was removed rather than fixed because it was never used — in the whole of
  production it had collected a handful of rows, from two senders, and not one
  invitation link was ever clicked.

  `down` restores both shapes but not their contents, which is honest rather
  than lazy: the invitation rows carried keyed email hashes that only this
  installation's `secret_key_base` can reproduce, and re-adding an empty
  `salutation` column would make every member look like they had declined one.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      remove(:salutation)
    end

    drop(table(:invitations))
  end

  def down do
    alter table(:users) do
      add(:salutation, :string)
    end

    create table(:invitations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:email_hash, :string, null: false)
      add(:locale, :string)
      add(:auto_follow, :boolean, default: false, null: false)
      add(:visited_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:invitations, [:email_hash]))
  end
end
