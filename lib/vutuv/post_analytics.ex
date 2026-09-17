defmodule Vutuv.PostAnalytics do
  @moduledoc """
  History of the engagement rows still stored for a post.

  This is not an impression count. Undo and deletion remove rows, so the
  historical curve describes currently retained reactions at their original
  arrival times rather than a complete audit log.
  """

  import Ecto.Query

  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Tags.SourceServers

  @ranges %{"7d" => {7, "hour"}, "30d" => {30, "hour"}, "1y" => {365, "day"}}
  @quiet_tail_days 2

  def ranges, do: ["7d", "30d", "1y"]

  def for_post(%Post{} = post, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    range = Keyword.get(opts, :range, "30d")
    {days, unit} = Map.get(@ranges, range, @ranges["30d"])
    range = if Map.has_key?(@ranges, range), do: range, else: "30d"
    start_at = DateTime.add(now, -days * 86_400, :second)
    published_at = DateTime.from_naive!(post.inserted_at, "Etc/UTC")
    first_at = Enum.max_by([start_at, published_at], &DateTime.to_unix/1)

    rows = events(post.id, unit, first_at, now)
    points = rows |> buckets(first_at, now, unit) |> trim_quiet_tail(unit)

    totals =
      Enum.reduce(points, %{likes: 0, reposts: 0, replies: 0, all: 0}, fn point, acc ->
        %{
          likes: acc.likes + point.likes,
          reposts: acc.reposts + point.reposts,
          replies: acc.replies + point.replies,
          all: acc.all + point.total
        }
      end)

    peak = Enum.max_by(points, & &1.total, fn -> nil end)
    known_readers = known_readers(post.id)
    repost_reach = repost_reach(post.id)
    network = network(post.id, totals, repost_reach)

    %{
      range: range,
      unit: unit,
      buckets: points,
      totals: totals,
      peak: peak,
      known_readers: known_readers,
      repost_reach: repost_reach,
      network: network
    }
  end

  defp known_readers(post_id) do
    sql = """
    SELECT count(DISTINCT reader)::integer
    FROM (
      SELECT 'local:' || user_id::text AS reader FROM post_likes WHERE post_id = $1
      UNION ALL
      SELECT 'local:' || user_id::text FROM post_reposts WHERE post_id = $1
      UNION ALL
      SELECT coalesce('local:' || p.user_id::text, 'page:' || p.organization_id::text)
        FROM post_replies r
        JOIN posts p ON p.id = r.post_id
        WHERE r.parent_post_id = $1 AND p.frozen_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.user_id
            AND (u.frozen_at IS NOT NULL OR u.deactivated_at IS NOT NULL
              OR u.unreachable_at IS NOT NULL OR u.suspended_until > (NOW() AT TIME ZONE 'utc')))
      UNION ALL
      SELECT 'remote:' || actor_uri FROM fediverse_reactions WHERE post_id = $1
      UNION ALL
      SELECT 'remote:' || actor_uri FROM fediverse_notes
        WHERE post_id = $1 AND audience = 'public'
    ) readers
    """

    %{rows: [[count]]} = Repo.query!(sql, [binary_id(post_id)])
    count
  end

  defp network(post_id, totals, repost_reach) do
    interaction_sql = """
    SELECT actor_uri, count(*)::integer,
           floor(extract(epoch FROM min(event_at)))::bigint AS first_seen_unix
    FROM (
      SELECT actor_uri, received_at AS event_at
        FROM fediverse_reactions WHERE post_id = $1
      UNION ALL
      SELECT actor_uri, received_at
        FROM fediverse_notes WHERE post_id = $1 AND audience = 'public'
    ) remote
    GROUP BY actor_uri
    """

    %{rows: interaction_rows} = Repo.query!(interaction_sql, [binary_id(post_id)])

    active =
      interaction_rows
      |> Enum.reduce(%{}, fn [uri, count, first_seen_unix], hosts ->
        Map.update(
          hosts,
          host(uri),
          %{interactions: count, first_seen_unix: first_seen_unix},
          fn current ->
            %{
              interactions: current.interactions + count,
              first_seen_unix: min(current.first_seen_unix, first_seen_unix)
            }
          end
        )
      end)
      |> Map.delete(nil)

    addressed = addressed_hosts(binary_ids([post_id]))
    origin = origin_host()
    remote_interactions = active |> Map.values() |> Enum.map(& &1.interactions) |> Enum.sum()
    local_interactions = totals.all - remote_interactions

    first_seen_unix =
      active |> Map.values() |> Enum.map(& &1.first_seen_unix) |> Enum.min(fn -> nil end)

    sequences = network_sequences(active, first_seen_unix)

    remote_nodes =
      (Map.keys(active) ++ addressed)
      |> Enum.uniq()
      |> remote_network_nodes(active, sequences, repost_reach.by_host)
      |> Enum.sort_by(&{-&1.interactions, &1.host})

    nodes = [
      %{
        host: origin,
        interactions: local_interactions,
        status: :origin,
        repost_potential: Map.get(repost_reach.by_host, origin, 0),
        first_seen_unix: nil,
        sequence: nil,
        elapsed_seconds: nil
      }
      | remote_nodes
    ]

    %{
      nodes: nodes,
      visible_nodes: visible_network_nodes(nodes),
      server_count: length(nodes),
      active_server_count: Enum.count(nodes, &(&1.interactions > 0)),
      hidden_server_count: max(length(nodes) - 19, 0),
      addressed_server_count: length(addressed)
    }
  end

  defp remote_network_nodes(hosts, active, sequences, repost_reach_by_host) do
    infos = SourceServers.infos(hosts)

    Enum.map(hosts, fn server ->
      remote_network_node(
        server,
        Map.get(active, server),
        Map.get(sequences, server),
        Map.get(infos, server),
        Map.get(repost_reach_by_host, server, 0)
      )
    end)
  end

  defp remote_network_node(server, activity, timing, info, repost_potential) do
    interactions = if activity, do: activity.interactions, else: 0
    timing = timing || %{sequence: nil, elapsed_seconds: nil}

    %{
      host: server,
      interactions: interactions,
      status: if(interactions > 0, do: :active, else: :addressed),
      active_month: info && info.active_month,
      node_info_checked_at: info && info.checked_at,
      repost_potential: repost_potential,
      first_seen_unix: activity && activity.first_seen_unix,
      sequence: timing.sequence,
      elapsed_seconds: timing.elapsed_seconds
    }
  end

  defp network_sequences(active, first_seen_unix) do
    active
    |> Enum.sort_by(fn {host, activity} -> {activity.first_seen_unix, host} end)
    |> Enum.with_index(1)
    |> Map.new(fn {{host, activity}, sequence} ->
      {host,
       %{
         sequence: sequence,
         elapsed_seconds: activity.first_seen_unix - first_seen_unix
       }}
    end)
  end

  defp visible_network_nodes([origin | remote_nodes]) do
    earliest =
      remote_nodes
      |> Enum.reject(&is_nil(&1.sequence))
      |> Enum.sort_by(& &1.sequence)
      |> Enum.take(6)

    visible_remote =
      (earliest ++ Enum.take(remote_nodes, 18))
      |> Enum.uniq_by(& &1.host)
      |> Enum.take(18)
      |> Enum.sort_by(fn node -> {is_nil(node.sequence), node.sequence || 0, node.host} end)

    [origin | visible_remote]
  end

  defp repost_reach(post_id) do
    summarize_reposters(local_reposters([post_id]) ++ remote_reposters([post_id]))
  end

  @doc """
  One row per repost by a member or page here of any of `post_ids`, carrying
  the reposter's current follower count (`nil` when the account behind it is
  gone) and the `post_id` it belongs to.

  A reposter of several posts is a row per post, which is what the per-post
  analysis sums and what `Vutuv.PostAnalytics.Year` adds up across a year.
  """
  def local_reposters(post_ids) do
    origin = origin_host()

    # The handle is all a row needs of its reposter, so it is selected rather
    # than preloaded with the whole account; the follower counts are two
    # grouped queries however many members and pages reposted.
    rows =
      from(r in PostRepost,
        left_join: u in assoc(r, :user),
        left_join: o in assoc(r, :organization),
        where: r.post_id in ^post_ids,
        select: %{
          post_id: r.post_id,
          user_id: u.id,
          username: u.username,
          organization_id: o.id,
          slug: o.slug
        }
      )
      |> Repo.all()

    member_counts = rows |> ids_of(:user_id) |> Social.follower_counts()
    page_counts = rows |> ids_of(:organization_id) |> Social.organization_follower_counts()

    Enum.map(rows, fn row ->
      row
      |> local_reposter(origin, member_counts, page_counts)
      |> Map.put(:post_id, row.post_id)
    end)
  end

  defp ids_of(rows, key),
    do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp local_reposter(%{user_id: id} = row, origin, member_counts, _page_counts)
       when is_binary(id),
       do: reposter(row.username, origin, Map.get(member_counts, id, 0), :local)

  defp local_reposter(%{organization_id: id} = row, origin, _member_counts, page_counts)
       when is_binary(id),
       do: reposter(row.slug, origin, Map.get(page_counts, id, 0), :local)

  defp local_reposter(_row, origin, _member_counts, _page_counts),
    do: reposter(nil, origin, nil, :local)

  @doc """
  One row per `Announce` from the Fediverse of any of `post_ids`, carrying the
  follower total last fetched for that account (`nil` while none is known) and
  the `post_id` it belongs to. Reads only what the background refresh stored;
  it never asks a remote server.
  """
  def remote_reposters(post_ids) do
    from(r in Reaction,
      left_join: a in RemoteAccount,
      on: a.actor_uri == r.actor_uri,
      where: r.post_id in ^post_ids and r.kind == "announce",
      select: %{
        post_id: r.post_id,
        actor_uri: r.actor_uri,
        reaction_handle: r.handle,
        host: a.host,
        account_handle: a.handle,
        followers: a.follower_count,
        checked_at: a.follower_count_checked_at
      }
    )
    |> Repo.all()
    |> Enum.map(&remote_reposter/1)
  end

  defp remote_reposter(row) do
    host = row.host || host(row.actor_uri) || "unknown"
    handle = row.account_handle || row.reaction_handle || actor_name(row.actor_uri)

    handle
    |> reposter(host, row.followers, :remote, row.checked_at)
    |> Map.put(:post_id, row.post_id)
  end

  defp summarize_reposters(reposters) do
    sorted =
      Enum.sort_by(
        reposters,
        fn row -> {is_nil(row.followers), -(row.followers || 0), row.label} end
      )

    sorted
    |> reach_tally()
    |> Map.merge(%{
      reposters: sorted,
      visible_reposters: Enum.take(sorted, 12),
      by_host: repost_reach_by_host(sorted)
    })
  end

  @doc """
  What a list of reposter rows adds up to: the sum of the follower counts that
  are known, how many rows have one, and how many do not. The per-post page and
  `Vutuv.PostAnalytics.Year` both count through here, so the yearly figure
  cannot come to mean something else.
  """
  def reach_tally(reposters) do
    known = reposters |> Enum.map(& &1.followers) |> Enum.reject(&is_nil/1)

    %{
      known: Enum.sum(known),
      known_reposters: length(known),
      unknown_reposters: length(reposters) - length(known)
    }
  end

  defp repost_reach_by_host(reposters) do
    reposters
    |> Enum.reject(&is_nil(&1.followers))
    |> Enum.group_by(& &1.host, & &1.followers)
    |> Map.new(fn {host, counts} -> {host, Enum.sum(counts)} end)
  end

  defp reposter(handle, host, followers, source, checked_at \\ nil) do
    label = if is_binary(handle), do: "@#{handle}@#{host}", else: host

    %{
      label: label,
      host: host,
      followers: followers,
      source: source,
      checked_at: checked_at
    }
  end

  defp actor_name(uri) when is_binary(uri) do
    uri |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename()
  end

  defp actor_name(_uri), do: nil

  defp host(uri) when is_binary(uri), do: uri |> URI.parse() |> Map.get(:host)
  defp host(_uri), do: nil

  defp origin_host, do: URI.parse(VutuvWeb.Endpoint.url()).host || "vutuv"

  defp binary_id(id) do
    {:ok, binary} = Ecto.UUID.dump(id)
    binary
  end

  defp binary_ids(ids), do: Enum.map(ids, &binary_id/1)

  # Every retained interaction with any of `$1` (an array of post ids), one row
  # per event with its arrival time and kind. The same public-reply gate used
  # by the post's visible counter excludes frozen and denied local replies and
  # non-public remote notes.
  @event_rows """
  SELECT inserted_at AS event_at, 'likes' AS kind FROM post_likes WHERE post_id = ANY($1)
  UNION ALL
  SELECT inserted_at, 'reposts' FROM post_reposts WHERE post_id = ANY($1)
  UNION ALL
  SELECT r.inserted_at, 'replies' FROM post_replies r
    JOIN posts p ON p.id = r.post_id
    WHERE r.parent_post_id = ANY($1) AND p.frozen_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = p.id)
      AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.user_id
        AND (u.frozen_at IS NOT NULL OR u.deactivated_at IS NOT NULL
          OR u.unreachable_at IS NOT NULL OR u.suspended_until > (NOW() AT TIME ZONE 'utc')))
  UNION ALL
  SELECT received_at, CASE kind WHEN 'like' THEN 'likes' ELSE 'reposts' END
    FROM fediverse_reactions WHERE post_id = ANY($1)
  UNION ALL
  SELECT received_at, 'replies' FROM fediverse_notes
    WHERE post_id = ANY($1) AND audience = 'public'
  """

  # Aggregate in PostgreSQL rather than sending one row per reaction to the
  # LiveView.
  defp events(post_id, unit, first_at, now) do
    sql = """
    SELECT date_trunc($2::text, event_at) AS bucket, kind, count(*)::integer
    FROM (#{@event_rows}) events
    WHERE event_at >= $3 AND event_at <= $4
    GROUP BY 1, 2
    ORDER BY 1
    """

    %{rows: rows} =
      Repo.query!(sql, [
        binary_ids([post_id]),
        unit,
        DateTime.to_naive(first_at),
        DateTime.to_naive(now)
      ])

    rows
  end

  @doc """
  The likes, reposts and public replies retained for any of `post_ids`, whenever
  they arrived, as `%{likes:, reposts:, replies:, all:}`. The totals the
  per-post chart adds up, without its time window.
  """
  def interaction_totals(post_ids) do
    sql = "SELECT kind, count(*)::integer FROM (#{@event_rows}) events GROUP BY kind"
    %{rows: rows} = Repo.query!(sql, [binary_ids(post_ids)])
    counts = Map.new(rows, fn [kind, count] -> {kind, count} end)
    [likes, reposts, replies] = Enum.map(~w(likes reposts replies), &Map.get(counts, &1, 0))

    %{likes: likes, reposts: reposts, replies: replies, all: likes + reposts + replies}
  end

  @doc """
  The Fediverse servers involved with any of `post_ids`, as `%{responded:,
  all:}` counts of distinct hosts: those an account liked, reposted or publicly
  answered from, and those together with the ones a copy was delivered to. The
  per-post network draws the same two kinds of node, without vutuv's own.
  """
  def server_counts(post_ids) do
    responded_sql = """
    SELECT actor_uri FROM fediverse_reactions WHERE post_id = ANY($1)
    UNION
    SELECT actor_uri FROM fediverse_notes WHERE post_id = ANY($1) AND audience = 'public'
    """

    ids = binary_ids(post_ids)
    responded = hosts(Repo.query!(responded_sql, [ids]).rows)

    %{
      responded: length(responded),
      all: (responded ++ addressed_hosts(ids)) |> Enum.uniq() |> length()
    }
  end

  # The distinct hosts a copy of any of `ids` (dumped post ids) was delivered to.
  defp addressed_hosts(ids) do
    sql = "SELECT DISTINCT inbox_uri FROM fediverse_post_deliveries WHERE post_id = ANY($1)"
    hosts(Repo.query!(sql, [ids]).rows)
  end

  defp hosts(rows) do
    rows |> Enum.map(fn [uri] -> host(uri) end) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp buckets(rows, first_at, now, unit) do
    counts =
      Map.new(rows, fn [at, kind, count] ->
        {{NaiveDateTime.truncate(at, :second), kind}, count}
      end)

    first = truncate(first_at, unit)
    last = truncate(now, unit)

    Stream.iterate(first, &advance(&1, unit))
    |> Enum.take_while(&(NaiveDateTime.compare(&1, last) != :gt))
    |> Enum.map(fn at ->
      likes = Map.get(counts, {at, "likes"}, 0)
      reposts = Map.get(counts, {at, "reposts"}, 0)
      replies = Map.get(counts, {at, "replies"}, 0)

      %{
        at: at,
        likes: likes,
        reposts: reposts,
        replies: replies,
        total: likes + reposts + replies
      }
    end)
  end

  # Keep gaps between waves because they explain a later peak. Only the empty
  # tail after the final visible interaction is shortened.
  defp trim_quiet_tail(points, unit) do
    last_active_index =
      points
      |> Enum.with_index()
      |> Enum.reduce(0, fn {point, index}, latest ->
        if point.total > 0, do: index, else: latest
      end)

    Enum.take(points, last_active_index + quiet_tail_buckets(unit) + 1)
  end

  defp quiet_tail_buckets("hour"), do: @quiet_tail_days * 24
  defp quiet_tail_buckets("day"), do: @quiet_tail_days

  defp truncate(datetime, "hour") do
    datetime |> DateTime.to_naive() |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})
  end

  defp truncate(datetime, "day") do
    datetime
    |> DateTime.to_naive()
    |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 0}})
  end

  defp advance(datetime, "hour"), do: NaiveDateTime.add(datetime, 3_600, :second)
  defp advance(datetime, "day"), do: NaiveDateTime.add(datetime, 86_400, :second)
end
