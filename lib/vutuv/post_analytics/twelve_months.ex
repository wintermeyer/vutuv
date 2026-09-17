defmodule Vutuv.PostAnalytics.TwelveMonths do
  @moduledoc """
  The reach of the last 12 months, for the investor page: the potential repost
  reach of every public post published in them, added up.

  **The 12 months are whole calendar months**, the current one included: from
  the first day of the month eleven months back until now. A rolling 365 days
  would cut the oldest bar of the monthly chart in half, and a calendar year
  would show two bars on the 2nd of January.

  **It is the per-post figure, summed**, and nothing cleverer. Each post
  contributes what its own reach analysis (`/posts/:id/analytics`) leads with:
  the current follower counts of the members and pages here who reposted it,
  plus the follower totals last fetched for the Fediverse accounts that did.
  Somebody who reposts three posts is counted three times, once per post,
  because that is three occasions on which their followers were handed
  something. Followers overlap and a delivered post may go unread, so the sum
  is potential distribution, not readership. A reposter whose total is unknown
  adds nothing and is counted separately, which makes the figure a lower bound.
  `Vutuv.PostAnalytics.TwelveMonthsTest` holds it equal to the sum of the per-post
  pages.

  **Public** means what an anonymous reader may open (`Posts.scope_visible/2`
  with no viewer), and a post belongs to the month it was published in (UTC).

  The work is split into `steps/0`, run in that order, each reported through
  the `:progress` callback the moment it finishes, with what it found and how
  long it took. That is what the investor page shows while it waits, so a
  step's report carries only the few figures a reader needs to follow along.
  Nothing here asks a remote server: follower totals are whatever the
  background refresh (`Vutuv.Fediverse.CountsRefresher`) last stored.
  """

  import Ecto.Query

  alias Vutuv.PostAnalytics
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  @steps [:posts, :local_reposts, :remote_reposts, :interactions, :servers]

  @doc "The keys of the steps a run reports, in the order it runs them."
  def steps, do: @steps

  @doc """
  Works out the reach of the 12 months up to now.

  Options: `:now` (a `DateTime`, the real clock by default), which also picks
  the months; `:progress`, called with each finished step as
  `%{key:, ms:, …figures}`.
  """
  def compute(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    progress = Keyword.get(opts, :progress, fn _step -> :ok end)
    months = months_up_to(now)
    since = hd(months)

    {posts_step, posts} = run(:posts, progress, fn -> public_posts(since, now) end)
    ids = Enum.map(posts, &elem(&1, 0))

    {local_step, local} =
      run(:local_reposts, progress, fn -> reposts(PostAnalytics.local_reposters(ids)) end)

    {remote_step, remote} =
      run(:remote_reposts, progress, fn -> reposts(PostAnalytics.remote_reposters(ids)) end)

    {interactions_step, totals} =
      run(:interactions, progress, fn -> PostAnalytics.interaction_totals(ids) end)

    {servers_step, servers} = run(:servers, progress, fn -> PostAnalytics.server_counts(ids) end)
    reposters = local.rows ++ remote.rows

    %{
      since: since,
      computed_at: now,
      posts: length(posts),
      reach: reposters |> PostAnalytics.reach_tally() |> Map.put(:reposts, length(reposters)),
      totals: totals,
      servers: servers,
      months: per_month(months, posts, reposters),
      steps: [posts_step, local_step, remote_step, interactions_step, servers_step]
    }
  end

  # Times one step, reports it, and hands its full result on. `summary` picks
  # the figures the report shows out of that result.
  defp run(key, progress, fun) do
    {microseconds, result} = :timer.tc(fun)
    step = Map.merge(%{key: key, ms: div(microseconds, 1_000)}, summary(key, result))
    progress.(step)
    {step, result}
  end

  defp summary(:posts, posts), do: %{count: length(posts)}

  defp summary(key, reposts) when key in [:local_reposts, :remote_reposts],
    do: %{
      reposts: length(reposts.rows),
      followers: reposts.known,
      unknown: reposts.unknown_reposters
    }

  defp summary(:interactions, totals), do: %{count: totals.all}
  defp summary(:servers, servers), do: %{count: servers.all, responded: servers.responded}

  # The first day of each of the 12 months that end with `now`'s, oldest first.
  defp months_up_to(now) do
    now
    |> DateTime.to_date()
    |> Date.beginning_of_month()
    |> Date.shift(month: -11)
    |> Stream.iterate(&Date.shift(&1, month: 1))
    |> Enum.take(12)
  end

  # `{id, first day of its month}` for every post an anonymous reader may open
  # that was published between `since` and `now`.
  defp public_posts(since, now) do
    from(p in Post,
      where: p.inserted_at >= ^NaiveDateTime.new!(since, ~T[00:00:00]),
      where: p.inserted_at <= ^DateTime.to_naive(now),
      select: {p.id, fragment("date_trunc('month', ?)::date", p.inserted_at)}
    )
    |> Posts.scope_visible(nil)
    |> Repo.all()
  end

  defp reposts(rows), do: rows |> PostAnalytics.reach_tally() |> Map.put(:rows, rows)

  # One entry per month, with the posts published in it and the reach they
  # brought, so a quiet month shows as a gap rather than being left out.
  defp per_month(months, posts, reposters) do
    month_of = Map.new(posts)
    posts_per_month = posts |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()

    reach_per_month =
      reposters
      |> Enum.reject(&is_nil(&1.followers))
      |> Enum.group_by(&Map.fetch!(month_of, &1.post_id), & &1.followers)
      |> Map.new(fn {month, followers} -> {month, Enum.sum(followers)} end)

    for month <- months do
      %{
        year: month.year,
        month: month.month,
        posts: Map.get(posts_per_month, month, 0),
        reach: Map.get(reach_per_month, month, 0)
      }
    end
  end
end
