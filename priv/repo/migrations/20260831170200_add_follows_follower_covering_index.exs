defmodule Vutuv.Repo.Migrations.AddFollowsFollowerCoveringIndex do
  use Ecto.Migration

  @moduledoc """
  Six of the feed's local sources embed the same follows subqueries (the
  followee id lists, `Vutuv.Posts.followees_of/1` and friends), and each one
  paid a seq scan over the whole table because no index covers all three
  columns the subqueries read — the planner needs `muted` and both followee
  columns beside the `follower_id` key to answer index-only.

  Measured on the production copy (2,679 follows, EXPLAIN of the real page
  queries in a rolled-back transaction): the eight affected queries drop from
  11.1 ms to 5.9 ms per feed arrival, each subplan scan from 0.5-1.4 ms to
  0.15-0.26 ms. The array-parameter alternative (fetch the id lists once in
  Elixir, pass them into the queries) was measured too and REGRESSED the page
  from 32 ms to 51 ms for a heavy follower - Postgres evaluates a parameter
  array linearly per row, while the hashed subplan and this index do not. So
  the subqueries stay and only get cheaper.

  The existing `follows_follower_id_followee_id_index` stays: the feed's
  EXISTS probes condition on `followee_id` as a key column, which an INCLUDE
  column cannot serve.
  """

  def change do
    create(
      index(:follows, [:follower_id],
        include: [:followee_id, :followee_organization_id, :muted],
        name: :follows_follower_covering_index
      )
    )
  end
end
