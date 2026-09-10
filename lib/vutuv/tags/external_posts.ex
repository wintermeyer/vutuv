defmodule Vutuv.Tags.ExternalPosts do
  @moduledoc """
  The pull behind a followed tag's other servers (issue #2126) and who gets to
  read what it brought back (issue #2127): which (tag, server) pairs are due,
  what one pass does to the clock, the two caps that bound the table, and the
  feed source and tag-page query that put the rows in front of somebody.

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

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.FeedPage
  alias Vutuv.Posts
  alias Vutuv.RateLimiter
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

  # How many of these a member may report a day. The same shape and the same
  # reasoning as the cached-post limit next door: a report empties our one copy
  # for everybody here, so it is a lever worth metering.
  @report_limit 20

  # --- What anybody may read (issue #2127) ----------------------------------

  @doc """
  The rows this installation may show at all, whatever surface is asking.

  Two refusals, and both are things the fetcher cannot settle because it stores
  one row for the whole installation and never looks at it again:

    * **a reported post**, whose words this table still holds only as the key
      that stops the next pull writing it back (`report/2`).
    * **a row with no author host**, which the release before #2127 wrote and
      this one can say nothing true about — a card would have to claim the
      author lives on the server we happened to ask. Failing closed costs a
      handful of rows from one deploy window, and the per-tag cap rolls those
      out within hours.

  **The operator's blocklist is deliberately not a third clause**, though it
  reads like the obvious place for one. Two layers already enforce it and a test
  that blocks a server passes without this: `Vutuv.Tags.ExternalTagClient`
  refuses a blocked source *and* drops a status whose author lives on a blocked
  host, and `Vutuv.Fediverse.purge_instance/1` takes these rows with everything
  else that server left here. That is the shape every cached remote post in this
  codebase is protected by — an ingest gate and a purge, never a read-path join
  — and "a blocked server leaves nothing at rest" is the stronger of the two
  promises anyway.

  Composable, and named `:external` so a caller can add its own clauses.
  """
  def showable_query do
    from(p in ExternalPost,
      as: :external,
      where: is_nil(p.reported_at),
      where: not is_nil(p.author_host)
    )
  end

  @doc """
  What a tag page may show under its **fediverse** tab (issue #2127) — the rows
  filed under `tag`, in the anonymous public view.

  Nothing narrower than `showable_query/0` is needed: only public statuses are
  ever stored (`Vutuv.Tags.ExternalTagClient` drops everything else on arrival),
  so unlike a cached ActivityPub object there is no audience to re-check here.
  """
  def tag_query(tag_id) when is_binary(tag_id) do
    if enabled?(),
      do: where(showable_query(), [external: p], p.tag_id == ^tag_id),
      # The switched-off arm keeps the `:external` binding: the caller composes
      # on it (`Vutuv.Tags.Timeline`'s union arm selects and filters through
      # it), and a query missing the name raises rather than answering nothing.
      else: from(p in ExternalPost, as: :external, where: false)
  end

  @doc """
  The feed source: what the servers **this** member's followed tags name have
  turned up, newest first.

  The rows are cached for the installation, so the whole question here is whose
  feed one reaches: the follow has to be this member's *and* name that server.
  A member who follows the same tag with vutuv alone sees none of it, however
  many of their neighbours pull from troet.cafe.

  Ordered and windowed on the author's own publication time — the stamp the card
  wears, exactly as a cached post's is — with `since_basis: :arrival` measured
  on `inserted_at`, when we found it, for the reader's unread marker.

  **A member who names no server pays one indexed lookup and no post query**,
  and that is almost everybody: measured on a copy of production, 20 of 6,027
  members follow any tag at all and one names a server. Without the guard the
  three-table join runs on every feed render, every unread badge on every page,
  and every month of the calendar's heatmap, for a table that cannot answer.
  The two sources next door short-circuit the same way and for the same reason
  (`Vutuv.Posts.feed_tag_items/3`, `Vutuv.Fediverse.feed_remote_posts/4`).
  """
  def feed_items(viewer, fetch_n, cursor, opts \\ [])

  def feed_items(%User{id: viewer_id} = viewer, fetch_n, cursor, opts) do
    shape = Keyword.get(opts, :shape, :entries)

    if enabled?() and names_a_server?(viewer_id) do
      viewer_id
      |> feed_query(fetch_n, shape)
      |> reject_muted_hosts(viewer)
      |> Posts.language_scope(Posts.feed_language_filter(viewer))
      |> FeedPage.time_window(cursor, :published_at, {:naive, :inserted_at})
      |> Repo.all()
      |> rows(shape)
    else
      []
    end
  end

  def feed_items(_viewer, _fetch_n, _cursor, _opts), do: []

  # `tag_follow_sources_source_tag_follow_id_index` is partial on exactly
  # `source <> 'vutuv'`, so this is an index-only probe: 0.16 ms measured,
  # against 2.5–3.5 ms of planning alone for the join it stands in front of.
  defp names_a_server?(viewer_id) do
    local = Tags.local_tag_follow_source()

    Repo.exists?(
      from(s in TagFollowSource,
        join: tf in TagFollow,
        on: tf.id == s.tag_follow_id,
        where: tf.user_id == ^viewer_id and s.source != ^local
      )
    )
  end

  defp feed_query(viewer_id, fetch_n, shape) do
    # The member's own follow and its own source row. One row per post: a member
    # follows a tag once (`tag_follows` is unique on the pair) and names a
    # server once, so this join cannot multiply a post out.
    #
    # `tf.user_id == ^viewer_id` is also what keeps a **page's** follow (issue
    # #1336, the nullable pair) out of a member's feed: a page follow carries a
    # NULL there, and NULL equals nothing.
    from([external: p] in showable_query(),
      join: tf in TagFollow,
      on: tf.tag_id == p.tag_id and tf.user_id == ^viewer_id,
      join: s in TagFollowSource,
      on: s.tag_follow_id == tf.id and s.source == p.source,
      order_by: [desc: p.published_at, desc: p.id],
      limit: ^fetch_n
    )
    |> select_shape(shape)
  end

  # A counter needs two columns and a page needs the row, and here that really
  # is all the database sends: a full row projects at 2,288 bytes against 24 for
  # the pair, so a month of the calendar's heatmap would otherwise decode
  # megabytes of somebody else's prose to produce thirty integers. Same shape
  # and same reason as `Vutuv.Fediverse`'s own `:marks` select.
  defp select_shape(query, :marks), do: select(query, [external: p], {p.id, p.published_at})
  defp select_shape(query, _entries), do: query

  # The reader's own switched-off servers (the feed band's list), read against
  # the **author's** host: a reader who muted mastodon.social meant the people
  # there, not the address we happened to read them from. No `is_nil(...) or`
  # in front of the `not in` — the NULL trap that guard exists for cannot fire
  # here, because `showable_query/0` has already dropped every row without one.
  defp reject_muted_hosts(query, viewer) do
    case Fediverse.muted_hosts(viewer) do
      [] -> query
      hosts -> where(query, [external: p], p.author_host not in ^hosts)
    end
  end

  # `:marks` is `Vutuv.FeedPage.mark/1`'s shape, so the two are interchangeable
  # and no source can be counted under a different definition than it is drawn
  # under. Built from the two columns the query selected rather than by taking
  # them off a whole entry, which would need the whole row.
  defp rows(pairs, :marks),
    do: for({id, at} <- pairs, do: %{id: "external-" <> id, at: DateTime.to_naive(at)})

  defp rows(posts, _entries), do: Enum.map(posts, &entry/1)

  @doc """
  One row as a feed entry.

  `post: nil` and its own `:external_post` key, which is what
  `Vutuv.Posts.external_feed_entry?/1` reads. The id prefix has to be unique
  across every source the paginator merges, and the stamp is naive UTC, which is
  what `Vutuv.FeedPage.sort_entries/1` compares.
  """
  def entry(%ExternalPost{} = post) do
    %{
      id: "external-" <> post.id,
      at: DateTime.to_naive(post.published_at),
      post: nil,
      external_post: post
    }
  end

  @doc """
  Somebody reports one of these as not appropriate.

  **Blanks it rather than deleting it.** Reporting a post cached from a followed
  account deletes the row, because nothing goes looking for it again; this table
  is re-read every ten minutes to three hours with `on_conflict: :nothing`, so a
  deleted row would simply be written back — a report that undoes itself is not
  a control. So the words go, the key stays, and every reader skips it
  (`showable_query/0`).

  Like its sibling this sends no `Flag` and opens no case: the post still stands
  on its own server, untouched, and what a member here can ask for is that this
  installation stop showing it. The takedown is recorded in the same
  content-free ledger, so the operator's "is this one troll or is this server
  the problem" question counts these alongside the rest.

  Rate limited per reporter.
  """
  def report(post_id, %User{} = reporter) do
    case RateLimiter.hit(
           {:external_tag_post_report, reporter.id},
           @report_limit,
           :timer.hours(24)
         ) do
      :ok -> take_down(post_id, reporter)
      _limited -> {:error, :rate_limited}
    end
  end

  defp take_down(post_id, %User{} = reporter) do
    case UUIDv7.with_cast(post_id, &Repo.get(ExternalPost, &1)) do
      %ExternalPost{reported_at: nil} = post ->
        blank(post)

        Fediverse.log_reported_post(%{
          host: post.author_host || post.source,
          # The author's own address where the server gave us one, the post's
          # otherwise: the ledger keeps only a keyed digest of it, and a digest
          # of nothing cannot be computed.
          actor_uri: post.author_url || post.url,
          audience: "public",
          actor_id: reporter.id
        })

        :ok

      _gone_or_already_reported ->
        {:error, :not_found}
    end
  end

  # What the row keeps is what the next pull's unique index needs: the tag, the
  # server, the remote id and the stamp. The words and the author go.
  defp blank(%ExternalPost{id: id}) do
    Repo.update_all(from(p in ExternalPost, where: p.id == ^id),
      set: [
        text: "",
        author_name: nil,
        author_acct: nil,
        author_url: nil,
        reported_at: DateTime.utc_now(:second),
        updated_at: NaiveDateTime.utc_now(:second)
      ]
    )
  end

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
    # removes rows: with a plain `LIMIT limit`, a server holding the first
    # `limit` due pairs would fill the candidate list on its own, the budget
    # would cut it to `per_host`, and **another** server's due pair — sitting
    # just past the cut — would never be looked at at all. The over-fetch is
    # what lets that pair into the list.
    #
    # It does not make the run bigger than what is due: where only one server
    # has pairs at all, a `per_host` of 2 serves 2, and that is the answer the
    # budget exists to give.
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
  `{:error, reason}` when the remote side failed — `:crashed` when the work
  raised or exited, which is a strike like any other failure, because from the
  scheduler's side an answer nobody could record is a failed ask.
  """
  def fetch_source(%{source: source} = row) do
    schedule = schedule_of(row)
    outcome = ask(row)

    # The clock is stamped **after** the outcome is in hand and can no longer be
    # thrown away by the work, and its own failure is caught rather than raised:
    # a pass that stops here would leave every pair behind it unstamped, holding
    # the front of the queue under `asc_nulls_first` and re-tried into the same
    # failure on every later run. That is #1316's shape widened from one wedged
    # pair to the whole fetcher.
    guard("clock for #{source}", fn -> stamp_outcome(schedule, outcome, source) end)

    outcome
  end

  # The ask and the store, with everything they can throw turned into an
  # ordinary outcome. The client rescues what it can see, but the store is
  # outside it and a stranger's server writes half of what goes into that
  # insert — so `:crashed` is a strike like any other failure, because from the
  # scheduler's side an answer nobody could record is a failed ask.
  defp ask(%{tag_id: tag_id, tag_name: tag_name, source: source}) do
    case guard(source, fn -> ExternalTagClient.fetch(source, tag_name) end) do
      {:ok, {:ok, posts}} -> {:ok, guarded_store(tag_id, posts, source)}
      {:ok, {:error, reason}} when reason in @skips -> {:skip, reason}
      {:ok, {:error, reason}} -> {:error, reason}
      :crashed -> {:error, :crashed}
    end
  end

  defp guarded_store(tag_id, posts, source) do
    case guard("store for #{source}", fn -> store(tag_id, posts) end) do
      {:ok, stored} -> stored
      :crashed -> 0
    end
  end

  defp stamp_outcome(schedule, {:ok, stored}, _source) do
    interval = next_interval(schedule.interval_seconds, stored)

    stamp(schedule, interval, %{
      interval_seconds: interval,
      strikes: 0,
      last_outcome: if(stored > 0, do: "stored", else: "empty")
    })
  end

  defp stamp_outcome(schedule, {:skip, reason}, source) do
    Logger.debug("external tag fetch skipped: #{source} (#{reason})")
    # Nothing about the pair moved, so the interval it had is the interval it
    # keeps; the ceiling is simply how long before anybody looks again.
    stamp(schedule, cadence()[:max_seconds], %{last_outcome: "skipped"})
  end

  defp stamp_outcome(schedule, {:error, _reason}, _source) do
    strikes = schedule.strikes + 1

    stamp(schedule, backoff(schedule.interval_seconds, strikes), %{
      strikes: strikes,
      last_outcome: "failed"
    })
  end

  # One guard for the three places a pair's work can throw, so the difference
  # between them is what each does with `:crashed` rather than four log strings
  # to keep in step. `{:ok, value}` or `:crashed` — never the value bare, or a
  # function legitimately answering `:crashed` could not be told apart.
  defp guard(what, fun) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.error("External tag fetch raised (#{what}): #{Exception.message(error)}")
      :crashed
  catch
    kind, value ->
      Logger.error("External tag fetch exited (#{what}): #{inspect({kind, value})}")
      :crashed
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
  #
  # **A reported row is never deleted here**, however old it gets. It is the
  # tombstone that stops the pull writing that status back (`report/2`), and a
  # tombstone that ages out is a report that quietly undoes itself the next time
  # its server still carries the post — which is the very failure blanking the
  # row rather than deleting it exists to prevent. What is left is the key, the
  # server and the stamp, so this bounds the table's *content* rather than its
  # row count; `prune/0` still takes them when nobody follows the pair any more,
  # which is the retention answer that matters.
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
              where: p.published_at < ^at or (p.published_at == ^at and p.id <= ^id),
              where: is_nil(p.reported_at)
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
