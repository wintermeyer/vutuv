defmodule Vutuv.Repo.Migrations.CreatePastFollows do
  @moduledoc """
  The span an ended follow was in force, kept after the follow row itself is
  gone (issue #1673).

  The feed is computed from the *current* follow set, so unfollowing erased the
  followee's whole back catalogue from it — including the posts that had reached
  the reader while they still followed. One row per ended follow says which of
  those posts still belong in that feed: the ones published between
  `started_at` (the follow's own `inserted_at`) and `ended_at`.

  No unique index, and none is wanted: following and unfollowing the same person
  twice leaves two spans, disjoint by construction since the second begins after
  the first ended. The nullable followee pair mirrors `follows` — a member or a
  page — under the same CHECK; the follower stays a member, because only members
  have a feed for a span to feed.

  New table, so N-1 compatible: the running release neither reads nor writes it.
  """
  use Ecto.Migration

  def change do
    create table(:past_follows) do
      add(:follower_id, references(:users, on_delete: :delete_all), null: false)
      add(:followee_id, references(:users, on_delete: :delete_all))
      add(:followee_organization_id, references(:organizations, on_delete: :delete_all))
      # Second precision, like every other timestamp here and like the
      # `posts.inserted_at` these are compared against.
      add(:started_at, :naive_datetime, null: false)
      add(:ended_at, :naive_datetime, null: false)

      timestamps()
    end

    create(
      constraint(:past_follows, :past_follows_exactly_one_followee,
        check: """
        (CASE WHEN followee_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN followee_organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    # The feed asks this table one question — "did this author reach me, and
    # when" — once per feed source per page. The author sits beside the reader
    # in the index and the date range is left to the row: a member's ended
    # follows of one author are a handful at most.
    create(index(:past_follows, [:follower_id, :followee_id]))
    create(index(:past_follows, [:follower_id, :followee_organization_id]))
  end
end
