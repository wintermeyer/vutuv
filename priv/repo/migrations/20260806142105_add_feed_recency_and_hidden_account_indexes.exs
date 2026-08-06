defmodule Vutuv.Repo.Migrations.AddFeedRecencyAndHiddenAccountIndexes do
  use Ecto.Migration

  # Two indexes for the newsfeed's main query ("posts of me and the people I
  # follow", newest first). Measured on a copy of production seeded to 200,000
  # posts: 76.7 ms -> 0.53 ms. Both are plain additions, so the release still
  # serving traffic during the blue/green switch is unaffected (N-1).
  #
  # 1. posts_recency_index — the feed, the tag timeline and the discovery rail
  #    all sort by (inserted_at DESC, id DESC), and nothing indexed that. Only
  #    (user_id, inserted_at) and (user_id, published_on) existed, and the
  #    feed's "my own posts OR posts of my followees" disjunction makes those
  #    unusable, so Postgres read the whole posts table and top-N sorted it on
  #    every single feed load.
  #
  # 2. users_hidden_index — Vutuv.Moderation.Query.account_hidden/1 asks for the
  #    accounts that are frozen, deactivated, unreachable or currently
  #    suspended, i.e. the *complement* of what users_visible_covering_index
  #    holds, so that index cannot serve it and Postgres scanned all of users
  #    to collect a few hundred ids — five times on one /feed.
  #
  #    The predicate says `suspended_until IS NOT NULL` rather than `> now()`:
  #    an index predicate has to be immutable and now() is not. The comparison
  #    then runs on the rows this index returns instead of on the whole table,
  #    which is the entire point.
  def change do
    create(index(:posts, ["inserted_at DESC", "id DESC"], name: :posts_recency_index))

    create(
      index(:users, [:id],
        name: :users_hidden_index,
        where:
          "frozen_at IS NOT NULL OR deactivated_at IS NOT NULL " <>
            "OR unreachable_at IS NOT NULL OR suspended_until IS NOT NULL"
      )
    )
  end
end
