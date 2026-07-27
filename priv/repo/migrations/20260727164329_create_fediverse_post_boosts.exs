defmodule Vutuv.Repo.Migrations.CreateFediversePostBoosts do
  use Ecto.Migration

  @moduledoc """
  What an account somebody here follows has **re-shared** (issue #1167).

  Much of what a followed account contributes is boosts, and until now every one
  of them fell through the inbox: an `Announce` only ever counted as a reaction
  to a vutuv member's own post, so a followed account resharing a third party
  was simply invisible to its followers here.

  One row per (booster, thing boosted). The booster is always a remote account —
  this is their act — and the thing boosted is either a **cached post** from
  another network or a **vutuv member's own post**, which is how members get
  discovered through the outside network and which needs no fetch at all.
  Exactly one of the two is set; two nullable references rather than a
  polymorphic pair, for the reason the reply sidecar gives: they are different
  tables with different lifetimes and a `{type, id}` column would only lose the
  foreign keys.

  `activity_id` is the `Announce`'s own id, because that is what an
  `Undo(Announce)` names — matching on actor and object would work for most
  implementations and not for the ones that boost the same post twice.

  Nothing here extends anybody's retention: a boosted copy lives under the
  ordinary clock. What the boost does buy it is a reason to exist at all while
  nobody here follows its author — see `purge_unfollowed_remote_posts/0`, which
  spares a post something still holds.
  """

  def change do
    create table(:fediverse_post_boosts) do
      add(:remote_account_id, references(:fediverse_remote_accounts, on_delete: :delete_all),
        null: false
      )

      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all))
      add(:post_id, references(:posts, on_delete: :delete_all))

      # The Announce's own id: unbounded in theory, so `text` like every other
      # remote URI here, capped in the changeset.
      add(:activity_id, :text)
      add(:announced_at, :utc_datetime, null: false)

      timestamps(updated_at: false)
    end

    # One booster boosting one thing is one boost, whichever kind it is. Two
    # partial indexes rather than one over both columns, since a null in a
    # unique index does not collide with anything.
    create(
      unique_index(:fediverse_post_boosts, [:remote_account_id, :remote_post_id],
        where: "remote_post_id IS NOT NULL",
        name: :fediverse_post_boosts_remote_index
      )
    )

    create(
      unique_index(:fediverse_post_boosts, [:remote_account_id, :post_id],
        where: "post_id IS NOT NULL",
        name: :fediverse_post_boosts_local_index
      )
    )

    # What an `Undo(Announce)` looks the row up by.
    create(index(:fediverse_post_boosts, [:activity_id]))
    # The cascades' own indexes, and the "is anything still holding this cached
    # post" question the purge asks.
    create(index(:fediverse_post_boosts, [:remote_post_id]))
    create(index(:fediverse_post_boosts, [:post_id]))
  end
end
