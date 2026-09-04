defmodule Vutuv.Repo.Migrations.CreateFediversePastFollows do
  @moduledoc """
  The span an ended follow of an account on another network was in force, kept
  after the follow row itself is gone (issue #1673) — the fediverse half of
  `past_follows`. `Vutuv.Fediverse.PastFollow` says what it is for.

  No unique index, and none is wanted: following and unfollowing the same
  account twice leaves two spans, disjoint by construction since the second
  begins after the first ended.

  New table, so N-1 compatible: the running release neither reads nor writes it.
  """
  use Ecto.Migration

  def change do
    create table(:fediverse_past_follows) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(
        :remote_account_id,
        references(:fediverse_remote_accounts, on_delete: :delete_all),
        null: false
      )

      # UTC, like every other timestamp on this side of the border and like the
      # `fediverse_posts.published_at` and `fediverse_post_boosts.announced_at`
      # these are compared against.
      add(:started_at, :utc_datetime, null: false)
      add(:ended_at, :utc_datetime, null: false)

      timestamps()
    end

    # What the two feed sources ask, once per candidate row: "did this account
    # reach me, and when". Both ends of the span ride along so the probe is
    # index-only — the range test is the whole point of the lookup, and without
    # them every probe would go to the heap for two timestamps.
    create(index(:fediverse_past_follows, [:user_id, :remote_account_id, :started_at, :ended_at]))

    # What the purge asks, which is the same question with nobody in it: "does
    # anybody's span still hold this copy". Reader-first would be no use to it.
    create(index(:fediverse_past_follows, [:remote_account_id, :started_at, :ended_at]))
  end
end
