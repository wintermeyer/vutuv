defmodule Vutuv.Repo.Migrations.WidenFollowerPrunesToAllOwnerKinds do
  @moduledoc """
  The prune ledger only ever knew members. `fediverse_followers` grew a page
  (#1334) and a topic (#1330) beside the member, but
  `fediverse_follower_prunes.user_id` stayed `NOT NULL` — so the day a page's or
  a topic's remote follower deleted their account, `prune_follower/2` wrote a
  NULL into it and the insert raised. The follower row was already deleted by
  then, which means the removal happened and simply never reached the
  Tagesbericht.

  Same shape as the followers table it mirrors: `user_id` becomes nullable,
  `organization_id` and `tag_id` join it, and a CHECK keeps exactly one of the
  three set, so the ledger cannot record a removal without saying who lost the
  follower.

  N-1 safe. Dropping NOT NULL is not a type change, so the previous release's
  cached prepared statements keep their result type (no 0A000). That release
  writes only member prunes, which satisfy the widened CHECK, and reads the
  ledger only through `Vutuv.Reports.daily/1`, which scopes nothing on the new
  columns — a page or topic row is invisible to it rather than confusing. The
  release after this one may assume all three.
  """
  use Ecto.Migration

  @check :fediverse_follower_prunes_exactly_one_owner

  def up do
    alter table(:fediverse_follower_prunes) do
      modify(:user_id, :binary_id, null: true, from: {:binary_id, null: false})
      add(:organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all))
      add(:tag_id, references(:tags, type: :binary_id, on_delete: :delete_all))
    end

    create(
      constraint(:fediverse_follower_prunes, @check,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN tag_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(index(:fediverse_follower_prunes, [:organization_id]))
    create(index(:fediverse_follower_prunes, [:tag_id]))
  end

  def down do
    drop(index(:fediverse_follower_prunes, [:tag_id]))
    drop(index(:fediverse_follower_prunes, [:organization_id]))
    drop(constraint(:fediverse_follower_prunes, @check))

    execute("DELETE FROM fediverse_follower_prunes WHERE user_id IS NULL")

    alter table(:fediverse_follower_prunes) do
      remove(:tag_id)
      remove(:organization_id)
      modify(:user_id, :binary_id, null: false, from: {:binary_id, null: true})
    end
  end
end
