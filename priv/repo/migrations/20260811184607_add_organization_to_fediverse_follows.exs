defmodule Vutuv.Repo.Migrations.AddOrganizationToFediverseFollows do
  @moduledoc """
  Issue #1336's last open point: a **page** can follow an account on another
  network. It was blocked until #1334 gave a page an actor of its own — a Follow
  has to be signed by somebody, and until v7.258.0 a page had nothing to sign
  with.

  Seventh table to take the nullable pair. The second unique index matters as
  much as the first: `[user_id, remote_account_id]` cannot stop a page following
  the same remote account twice, because those rows leave `user_id` NULL and
  Postgres treats NULLs as distinct.

  `follow_activity_id` stays globally unique across both kinds, and that is
  deliberate rather than incidental: it is the join between the two halves of
  the handshake — the other server echoes it back inside its `Accept`, and that
  string is how the answer finds its row. Two rows sharing one would make an
  `Accept` ambiguous.

  N-1 safe: the previous release only writes member follows, which satisfy the
  CHECK, and every query it runs is scoped to a real `user_id`.
  """
  use Ecto.Migration

  def up do
    alter table(:fediverse_follows) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE fediverse_follows ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:fediverse_follows, :fediverse_follows_exactly_one_follower,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:fediverse_follows, [:organization_id, :remote_account_id]))
  end

  def down do
    drop(unique_index(:fediverse_follows, [:organization_id, :remote_account_id]))
    drop(constraint(:fediverse_follows, :fediverse_follows_exactly_one_follower))

    execute("DELETE FROM fediverse_follows WHERE user_id IS NULL")
    execute("ALTER TABLE fediverse_follows ALTER COLUMN user_id SET NOT NULL")

    alter table(:fediverse_follows) do
      remove(:organization_id)
    end
  end
end
