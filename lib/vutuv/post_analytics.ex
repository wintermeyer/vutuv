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
    points = buckets(rows, first_at, now, unit)

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
    SELECT actor_uri, count(*)::integer
    FROM (
      SELECT actor_uri FROM fediverse_reactions WHERE post_id = $1
      UNION ALL
      SELECT actor_uri FROM fediverse_notes WHERE post_id = $1 AND audience = 'public'
    ) remote
    GROUP BY actor_uri
    """

    delivery_sql = """
    SELECT DISTINCT inbox_uri FROM fediverse_post_deliveries WHERE post_id = $1
    """

    id = binary_id(post_id)
    %{rows: interaction_rows} = Repo.query!(interaction_sql, [id])
    %{rows: delivery_rows} = Repo.query!(delivery_sql, [id])

    active =
      interaction_rows
      |> Enum.reduce(%{}, fn [uri, count], hosts ->
        Map.update(hosts, host(uri), count, &(&1 + count))
      end)
      |> Map.delete(nil)

    addressed = delivery_rows |> Enum.map(fn [uri] -> host(uri) end) |> Enum.reject(&is_nil/1)
    origin = URI.parse(VutuvWeb.Endpoint.url()).host || "vutuv"
    local_interactions = totals.all - Enum.sum(Map.values(active))

    remote_nodes =
      (Map.keys(active) ++ addressed)
      |> Enum.uniq()
      |> then(fn hosts -> {hosts, SourceServers.infos(hosts)} end)
      |> then(fn {hosts, infos} ->
        Enum.map(hosts, fn server ->
          interactions = Map.get(active, server, 0)
          info = Map.get(infos, server)

          %{
            host: server,
            interactions: interactions,
            status: if(interactions > 0, do: :active, else: :addressed),
            active_month: info && info.active_month,
            node_info_checked_at: info && info.checked_at,
            repost_potential: Map.get(repost_reach.by_host, server, 0)
          }
        end)
      end)
      |> Enum.sort_by(&{-&1.interactions, &1.host})

    nodes = [
      %{
        host: origin,
        interactions: local_interactions,
        status: :origin,
        repost_potential: Map.get(repost_reach.by_host, origin, 0)
      }
      | remote_nodes
    ]

    %{
      nodes: nodes,
      visible_nodes: Enum.take(nodes, 19),
      server_count: length(nodes),
      active_server_count: Enum.count(nodes, &(&1.interactions > 0)),
      hidden_server_count: max(length(nodes) - 19, 0),
      addressed_server_count: length(Enum.uniq(addressed))
    }
  end

  defp repost_reach(post_id) do
    origin = URI.parse(VutuvWeb.Endpoint.url()).host || "vutuv"
    reposters = local_reposters(post_id, origin) ++ remote_reposters(post_id)
    summarize_reposters(reposters)
  end

  defp local_reposters(post_id, origin) do
    local_rows =
      from(r in PostRepost, where: r.post_id == ^post_id)
      |> Repo.all()
      |> Repo.preload([:user, :organization])

    user_ids = local_rows |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1)
    follower_counts = Social.follower_counts(user_ids)

    Enum.map(local_rows, &local_reposter(&1, origin, follower_counts))
  end

  defp local_reposter(%{user: %{} = user}, origin, follower_counts) do
    reposter(user.username, origin, Map.get(follower_counts, user.id, 0), :local)
  end

  defp local_reposter(%{organization: %{} = organization}, origin, _follower_counts) do
    followers = Social.organization_follower_count(organization)
    reposter(organization.slug, origin, followers, :local)
  end

  defp local_reposter(_repost, origin, _follower_counts),
    do: reposter(nil, origin, nil, :local)

  defp remote_reposters(post_id) do
    from(r in Reaction,
      left_join: a in RemoteAccount,
      on: a.actor_uri == r.actor_uri,
      where: r.post_id == ^post_id and r.kind == "announce",
      select: %{
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
    reposter(handle, host, row.followers, :remote, row.checked_at)
  end

  defp summarize_reposters(reposters) do
    sorted =
      Enum.sort_by(
        reposters,
        fn row -> {is_nil(row.followers), -(row.followers || 0), row.label} end
      )

    known = sorted |> Enum.map(& &1.followers) |> Enum.reject(&is_nil/1) |> Enum.sum()

    %{
      known: known,
      known_reposters: Enum.count(sorted, &(not is_nil(&1.followers))),
      unknown_reposters: Enum.count(sorted, &is_nil(&1.followers)),
      reposters: sorted,
      visible_reposters: Enum.take(sorted, 12),
      by_host: repost_reach_by_host(sorted)
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

  defp binary_id(id) do
    {:ok, binary} = Ecto.UUID.dump(id)
    binary
  end

  # Aggregate in PostgreSQL rather than sending one row per reaction to the
  # LiveView. The same public-reply gate used by the post's visible counter
  # excludes frozen and denied local replies and non-public remote notes.
  defp events(post_id, unit, first_at, now) do
    sql = """
    SELECT date_trunc($2::text, event_at) AS bucket, kind, count(*)::integer
    FROM (
      SELECT inserted_at AS event_at, 'likes' AS kind FROM post_likes WHERE post_id = $1
      UNION ALL
      SELECT inserted_at, 'reposts' FROM post_reposts WHERE post_id = $1
      UNION ALL
      SELECT r.inserted_at, 'replies' FROM post_replies r
        JOIN posts p ON p.id = r.post_id
        WHERE r.parent_post_id = $1 AND p.frozen_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.user_id
            AND (u.frozen_at IS NOT NULL OR u.deactivated_at IS NOT NULL
              OR u.unreachable_at IS NOT NULL OR u.suspended_until > (NOW() AT TIME ZONE 'utc')))
      UNION ALL
      SELECT received_at, CASE kind WHEN 'like' THEN 'likes' ELSE 'reposts' END
        FROM fediverse_reactions WHERE post_id = $1
      UNION ALL
      SELECT received_at, 'replies' FROM fediverse_notes
        WHERE post_id = $1 AND audience = 'public'
    ) events
    WHERE event_at >= $3 AND event_at <= $4
    GROUP BY 1, 2
    ORDER BY 1
    """

    %{rows: rows} =
      Repo.query!(sql, [
        binary_id(post_id),
        unit,
        DateTime.to_naive(first_at),
        DateTime.to_naive(now)
      ])

    rows
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
