defmodule Vutuv.Tags.ExternalPosts do
  @moduledoc """
  The pull behind a followed tag's other servers (issue #2126): which
  (tag, server) pairs are due, what one pass does to the clock, and the two
  caps that bound the table.

  A follow names its sources since issue #2125 — `vutuv` plus any server the
  member picked — and this is what makes that mean something. Nothing is
  delivered to us: a hashtag has no inbox, so each server is asked for its
  public tag timeline (`Vutuv.Tags.ExternalTagClient`) and what comes back is
  kept as **text and a link to the original**, never a picture.

  Which pairs anybody wants is `Vutuv.Tags.wanted_tag_sources_query/0`, the
  query #2125 shipped for this consumer; what is added here is the schedule
  beside it (`Vutuv.Tags.ExternalFetch`, whose moduledoc owns the clock rule)
  and the due filter over it.

  ## How often

  The tag's own business. A pass aims at roughly `target` new posts between two
  fetches: more than that arrived and the interval halves, none arrived and it
  doubles, always inside the floor and the ceiling (ten minutes to three
  hours). A tag in the middle of a news event settles at the floor and a quiet
  local one drifts out to the ceiling on its own, with no list of "busy tags"
  for anybody to maintain.

  A **budget per server** is applied to the due list before anything is asked,
  so twenty busy tags naming one popular server cannot spend its rate limit in
  one run. It is a fairness cap over an already-sorted list, which is only safe
  because every outcome moves the pair's clock: the pairs it holds back are the
  ones the *next* run serves first.

  ## What bounds the table

  Two caps, both enforced after a store that added something: at most `per_tag`
  posts for one tag (its sources share those slots, newest wins) and at most
  `total` rows in the whole table. And `prune/0` takes a pair's posts away with
  the last follow that wanted them, so nothing here outlives somebody's interest
  in it — which is also the retention answer for words their author never
  offered us.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalFetch
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.Tags.ExternalTagClient
  alias Vutuv.Tags.TagFollow
  alias Vutuv.Tags.TagFollowSource
  alias Vutuv.UUIDv7

  @flag :fetch_external_tag_posts

  @cadence [target: 5, min_seconds: 600, max_seconds: 10_800]
  @caps [per_tag: 20, total: 10_000]
  @budget [batch: 20, per_host: 5]

  # A refusal that is nobody's fault and may be lifted from outside: the
  # operator's blocklist, an internal resolution, a server that will not serve
  # this timeline. No strike, and the ceiling before the next look.
  @skips [:blocked, :internal, :gone]

  # The columns a stored post carries, taken from the schema so a new one cannot
  # be forgotten in the row map below and silently stay NULL.
  @post_columns ExternalPost.__schema__(:fields) -- [:id, :inserted_at, :updated_at]

  @empty_tally %{fetched: 0, stored: 0, skipped: 0, failed: 0}

  @doc """
  Whether this installation reads other servers' tag timelines at all.

  The intranet switch, and the one that keeps the sweeper out of the test
  supervision tree — off, nothing is asked and the child never starts.
  """
  def enabled?, do: Application.get_env(:vutuv, @flag, true) == true

  @doc "The pace a tag's pull drifts between: `target`, `min_seconds`, `max_seconds`."
  def cadence, do: Application.get_env(:vutuv, :external_tag_cadence, @cadence)

  @doc "What bounds the table: `per_tag` posts for one tag, `total` rows overall."
  def caps, do: Application.get_env(:vutuv, :external_tag_post_caps, @caps)

  @doc "The ceilings on one run: `batch` pairs in total, `per_host` of them per server."
  def budget, do: Application.get_env(:vutuv, :external_tag_fetch_budget, @budget)

  @doc """
  One pass: ask every due pair, store what came back, and keep the table inside
  its ceiling when something was actually added.

  Sequential on purpose — the next run is scheduled after this one finishes
  (`Vutuv.Tags.ExternalPostFetcher`), so runs cannot pile up on a slow network.
  Forgetting pairs nobody wants any more is `prune/0`, on its own far slower
  clock: it reacts to a member unfollowing something, which no fetch can change.
  """
  def fetch_due do
    if enabled?() do
      tally = due_sources() |> Enum.map(&fetch_source/1) |> tally()
      if tally.stored > 0, do: enforce_ceiling()
      tally
    else
      @empty_tally
    end
  end

  @doc """
  The (tag, server) pairs due to be asked, least recently due first and capped
  at the budget's `per_host` per server.

  A pair that has never been fetched has no schedule row and comes first; ties
  go to the pair the most people here follow. Each row carries the pair's own
  schedule, so working through the list costs no further query.
  """
  def due_sources(limit \\ budget()[:batch]) do
    now = DateTime.utc_now(:second)

    # More candidates than the batch, because the per-server budget below
    # removes rows: taking exactly `limit` from SQL would let one busy server
    # shrink the run instead of sharing it.
    now
    |> due_query(limit * 4)
    |> Repo.all()
    |> cap_per_host(budget()[:per_host])
    |> Enum.take(limit)
  end

  defp due_query(now, limit) do
    Tags.wanted_tag_sources_query()
    |> join(:left, [source: s, tag: t], f in ExternalFetch,
      as: :fetch,
      on: f.tag_id == t.id and f.source == s.source
    )
    # `where`, not `having`: the pair's unique index on the schedule table
    # guarantees at most one joined row per group, so the filter needs no
    # aggregate — and down there it runs on the join instead of on every group
    # the installation has, which is the difference between filtering ~80 rows
    # and sorting all of them.
    |> where([fetch: f], is_nil(f.id) or f.next_fetch_at <= ^now)
    |> group_by([fetch: f], [f.id, f.next_fetch_at, f.interval_seconds, f.strikes])
    |> order_by([source: s, fetch: f],
      asc_nulls_first: f.next_fetch_at,
      desc: count(s.id),
      asc: s.source
    )
    |> select_merge([fetch: f], %{
      interval_seconds: f.interval_seconds,
      strikes: f.strikes
    })
    |> limit(^limit)
  end

  # The third instance of this reduce in the tree (`Vutuv.Fediverse` holds two,
  # both private and both wired to their own config), so it is written out again
  # rather than shared; what does carry over is the log, because a cap nobody
  # can see reads as "we asked about everything".
  defp cap_per_host(rows, per_host) do
    {kept, _seen} =
      Enum.reduce(rows, {[], %{}}, fn row, {kept, seen} ->
        taken = Map.get(seen, row.source, 0)

        if taken < per_host,
          do: {[row | kept], Map.put(seen, row.source, taken + 1)},
          else: {kept, seen}
      end)

    held_back = length(rows) - length(kept)

    if held_back > 0 do
      Logger.info("External tag posts: #{held_back} due pair(s) held back by the per-server cap")
    end

    Enum.reverse(kept)
  end

  @doc """
  Asks one pair's server and records the outcome. Always stamps the clock —
  see `Vutuv.Tags.ExternalFetch` for why that is the whole point.

  `{:ok, stored}` when the server answered (storing nothing is an ordinary
  answer), `{:skip, reason}` when the pair cannot be asked at all, and
  `{:error, reason}` when the remote side failed.
  """
  def fetch_source(%{tag_id: tag_id, tag_name: tag_name, source: source} = row) do
    schedule = schedule_of(row)

    case ExternalTagClient.fetch(source, tag_name) do
      {:ok, posts} ->
        stored = store(tag_id, posts)
        interval = next_interval(schedule.interval_seconds, stored)

        stamp(schedule, interval, %{
          interval_seconds: interval,
          strikes: 0,
          last_outcome: if(stored > 0, do: "stored", else: "empty")
        })

        {:ok, stored}

      {:error, reason} when reason in @skips ->
        Logger.debug("external tag fetch skipped: #{source} (#{reason})")
        # Nothing about the pair moved, so the interval it had is the interval
        # it keeps; the ceiling is simply how long before anybody looks again.
        stamp(schedule, cadence()[:max_seconds], %{last_outcome: "skipped"})
        {:skip, reason}

      {:error, reason} ->
        strikes = schedule.strikes + 1

        stamp(schedule, backoff(schedule.interval_seconds, strikes), %{
          strikes: strikes,
          last_outcome: "failed"
        })

        {:error, reason}
    end
  end

  # The due query carried the pair's schedule along, so there is nothing to look
  # up; a pair being asked for the first time starts at the floor.
  defp schedule_of(%{tag_id: tag_id, source: source} = row) do
    %ExternalFetch{
      tag_id: tag_id,
      source: source,
      interval_seconds: row[:interval_seconds] || cadence()[:min_seconds],
      strikes: row[:strikes] || 0
    }
  end

  # Doubling per consecutive strike, and never past the ceiling: a server having
  # a bad day must not see us return every ten minutes, and a dead one costs
  # eight asks a day.
  defp backoff(interval, strikes) do
    interval
    |> Kernel.*(Integer.pow(2, min(strikes, 8)))
    |> min(cadence()[:max_seconds])
  end

  defp stamp(schedule, seconds_until_next, attrs) do
    now = DateTime.utc_now(:second)

    params =
      %{
        tag_id: schedule.tag_id,
        source: schedule.source,
        interval_seconds: schedule.interval_seconds,
        strikes: schedule.strikes,
        checked_at: now,
        next_fetch_at: DateTime.add(now, seconds_until_next)
      }
      |> Map.merge(attrs)

    # One statement, so two overlapping runs (the blue/green window) cannot
    # collide on the pair's unique index.
    %ExternalFetch{}
    |> ExternalFetch.changeset(params)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:checked_at, :next_fetch_at, :interval_seconds, :strikes, :last_outcome, :updated_at]},
      conflict_target: [:tag_id, :source]
    )
  end

  @doc """
  The next interval for a pair that just stored `stored` posts.

  Aims at `target` new posts per fetch: half the wait when far more arrived,
  double it when none did, at most one halving or doubling per pass so a single
  odd fetch cannot fling the pace across the whole range — and always inside
  the floor and the ceiling.
  """
  def next_interval(current, stored) do
    cadence = cadence()

    current
    |> Kernel.*(cadence[:target] / max(stored, 0.5))
    |> round()
    |> min(current * 2)
    |> max(div(current, 2))
    |> min(cadence[:max_seconds])
    |> max(cadence[:min_seconds])
  end

  defp store(tag_id, posts) do
    now = NaiveDateTime.utc_now(:second)

    # The schema, never a bare table name: a schemaless insert_all holds no
    # field types and hands Postgrex a readable UUID string it cannot encode.
    # `on_conflict: :nothing` makes the count the number of rows that were
    # really new, which is what the cadence reads.
    {stored, nil} =
      Repo.insert_all(ExternalPost, Enum.flat_map(posts, &row(&1, tag_id, now)),
        on_conflict: :nothing,
        conflict_target: [:tag_id, :source, :remote_id]
      )

    # A tag polled at the floor mostly re-reads what it already holds, and
    # trimming what nothing was added to is two queries that can delete nothing.
    if stored > 0, do: trim(from(p in ExternalPost, where: p.tag_id == ^tag_id), caps()[:per_tag])

    stored
  end

  # Through the changeset, because these values were written by a stranger's
  # server: an oversized one would otherwise raise Postgres 22001 on a path
  # with no form in front of it and abort the whole batch.
  defp row(attrs, tag_id, now) do
    changeset = ExternalPost.changeset(%ExternalPost{}, Map.put(attrs, :tag_id, tag_id))

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, post} ->
        [
          post
          |> Map.take(@post_columns)
          |> Map.merge(%{id: UUIDv7.generate(), inserted_at: now, updated_at: now})
        ]

      {:error, _changeset} ->
        []
    end
  end

  @doc """
  Drops the oldest rows once the whole table is over its ceiling, whatever tag
  they belong to. Answers how many went.
  """
  def enforce_ceiling, do: trim(ExternalPost, caps()[:total])

  # Keeps the newest `cap` rows of `scope` and deletes the rest, by the keyset
  # the table's index is built on. One shape for both caps: the per-tag one is
  # this scoped to a tag, and reading them as two algorithms is how the two
  # orderings drift apart.
  defp trim(scope, cap) do
    boundary =
      Repo.one(
        from(p in scope,
          order_by: [desc: p.published_at, desc: p.id],
          offset: ^cap,
          limit: 1,
          select: %{published_at: p.published_at, id: p.id}
        )
      )

    case boundary do
      nil ->
        0

      %{published_at: at, id: id} ->
        {dropped, _} =
          Repo.delete_all(
            from(p in scope,
              where: p.published_at < ^at or (p.published_at == ^at and p.id <= ^id)
            )
          )

        dropped
    end
  end

  @doc """
  Forgets every pair nobody names any more: its schedule first, then the posts
  it brought. Answers `%{fetches: n, posts: n}`.

  Its own job rather than part of a fetch, and on a far slower clock (see
  `Vutuv.Tags.ExternalPostFetcher`): what it reacts to is somebody dropping a
  source or unfollowing a tag, which no fetch can bring about, and both deletes
  scan a table to find nothing on an ordinary day.

  Written as two `NOT EXISTS` deletes rather than a list of wanted pairs held in
  memory, so each stays one bounded statement however many follows exist — and
  `NOT EXISTS` cannot fall into the `NOT IN (…, NULL)` trap that costs this
  codebase a silent empty answer whenever a nullable column joins a subquery.
  """
  def prune do
    # The correlated twin of `Tags.wanted_tag_sources_query/0` — the same
    # question asked per row rather than grouped, which is the one shape that
    # query cannot be composed into.
    local = Tags.local_tag_follow_source()

    wanted =
      from(s in TagFollowSource,
        join: tf in TagFollow,
        on: tf.id == s.tag_follow_id,
        where:
          s.source != ^local and s.source == parent_as(:fetch).source and
            tf.tag_id == parent_as(:fetch).tag_id
      )

    {fetches, _} =
      Repo.delete_all(from(f in ExternalFetch, as: :fetch, where: not exists(wanted)))

    scheduled =
      from(f in ExternalFetch,
        where: f.source == parent_as(:post).source and f.tag_id == parent_as(:post).tag_id
      )

    {posts, _} = Repo.delete_all(from(p in ExternalPost, as: :post, where: not exists(scheduled)))

    %{fetches: fetches, posts: posts}
  end

  defp tally(results) do
    Enum.reduce(results, @empty_tally, fn
      {:ok, stored}, acc -> %{acc | fetched: acc.fetched + 1, stored: acc.stored + stored}
      {:skip, _reason}, acc -> %{acc | skipped: acc.skipped + 1}
      {:error, _reason}, acc -> %{acc | failed: acc.failed + 1}
    end)
  end
end
