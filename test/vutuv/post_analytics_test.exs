defmodule Vutuv.PostAnalyticsTest do
  use Vutuv.DataCase

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.PostAnalytics
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags.SourceServer

  test "buckets locally recorded and remote engagement by hour" do
    author = insert(:activated_user)
    reader = insert(:activated_user)
    earlier_reader = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A post worth measuring"})
    now = DateTime.add(DateTime.utc_now(:second), 7_200, :second)

    Repo.insert!(%Vutuv.Posts.PostLike{
      post_id: post.id,
      user_id: earlier_reader.id,
      inserted_at: now |> DateTime.add(-3_600, :second) |> DateTime.to_naive()
    })

    Repo.insert!(%Vutuv.Posts.PostLike{
      post_id: post.id,
      user_id: reader.id,
      inserted_at: DateTime.to_naive(now)
    })

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/booster",
      kind: "announce",
      received_at: now
    })

    result = PostAnalytics.for_post(post, range: "7d", now: now)

    assert result.totals.likes == 2
    assert result.totals.reposts == 1
    assert result.totals.replies == 0
    assert result.totals.all == 3
    assert Enum.sum(Enum.map(result.buckets, & &1.total)) == 3
    assert Enum.count(result.buckets, &(&1.total > 0)) == 2
    assert result.peak.total == 2
  end

  test "uses hourly buckets for the 30-day analysis" do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A month in hours"})

    result = PostAnalytics.for_post(post, range: "30d")

    assert result.unit == "hour"
  end

  test "stops the hourly chart after two quiet days" do
    author = insert(:activated_user)
    reader = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A post whose momentum ended"})
    reacted_at = DateTime.utc_now(:second)
    now = DateTime.add(reacted_at, 5 * 86_400, :second)

    Repo.insert!(%Vutuv.Posts.PostLike{
      post_id: post.id,
      user_id: reader.id,
      inserted_at: DateTime.to_naive(reacted_at)
    })

    result = PostAnalytics.for_post(post, range: "7d", now: now)
    last_bucket = List.last(result.buckets)
    active_bucket = Enum.find(result.buckets, &(&1.total > 0))

    assert NaiveDateTime.diff(last_bucket.at, active_bucket.at) == 48 * 3_600
  end

  test "keeps a later peak after more than two quiet days" do
    author = insert(:activated_user)
    first_reader = insert(:activated_user)
    later_reader = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A post with a second wave"})
    first_at = DateTime.utc_now(:second)
    later_at = DateTime.add(first_at, 4 * 86_400, :second)
    now = DateTime.add(later_at, 3_600, :second)

    for {reader, reacted_at} <- [{first_reader, first_at}, {later_reader, later_at}] do
      Repo.insert!(%Vutuv.Posts.PostLike{
        post_id: post.id,
        user_id: reader.id,
        inserted_at: DateTime.to_naive(reacted_at)
      })
    end

    result = PostAnalytics.for_post(post, range: "7d", now: now)
    active_buckets = Enum.filter(result.buckets, &(&1.total > 0))

    assert length(active_buckets) == 2
    assert NaiveDateTime.diff(List.last(active_buckets).at, hd(active_buckets).at) == 4 * 86_400
  end

  test "counts the member followers of pages that reposted, one count per page" do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A post two pages shared"})
    followed = insert(:organization)
    unfollowed = insert(:organization)

    for _ <- 1..2 do
      {:ok, _follow} = Vutuv.Social.follow_organization(insert(:activated_user), followed)
    end

    for page <- [followed, unfollowed] do
      Repo.insert!(%Vutuv.Posts.PostRepost{post_id: post.id, organization_id: page.id})
    end

    reach = PostAnalytics.for_post(post).repost_reach

    assert reach.known == 2
    assert reach.known_reposters == 2
    assert Enum.find(reach.reposters, &(&1.label =~ followed.slug)).followers == 2
    assert Enum.find(reach.reposters, &(&1.label =~ unfollowed.slug)).followers == 0
  end

  test "summarizes known readers and the servers involved in distribution" do
    author = insert(:activated_user)
    reader = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "A post crossing server borders"})
    now = DateTime.add(DateTime.utc_now(:second), 60, :second)

    Repo.insert!(%Vutuv.Posts.PostLike{post_id: post.id, user_id: reader.id})
    Repo.insert!(%Vutuv.Posts.PostRepost{post_id: post.id, user_id: reader.id})

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/alice",
      kind: "like",
      received_at: now
    })

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/alice",
      kind: "announce",
      received_at: now
    })

    Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://community.example/people/bob",
      kind: "like",
      received_at: DateTime.add(now, 600, :second)
    })

    Repo.insert!(%RemoteAccount{
      actor_uri: "https://social.example/users/alice",
      host: "social.example",
      handle: "alice",
      inbox_uri: "https://social.example/users/alice/inbox",
      follower_count: 10_000,
      follower_count_checked_at: DateTime.add(now, -600, :second)
    })

    Repo.insert!(%Vutuv.Fediverse.PostDelivery{
      post_id: post.id,
      user_id: author.id,
      inbox_uri: "https://relay.example/inbox",
      object_uri: "https://vutuv.test/#{author.username}/posts/#{post.id}"
    })

    checked_at = DateTime.add(now, -3_600, :second)

    Repo.insert!(%SourceServer{
      host: "social.example",
      active_month: 12_345,
      status: "ok",
      checked_at: checked_at
    })

    result = PostAnalytics.for_post(post, range: "7d", now: now)

    assert result.known_readers == 3
    assert result.network.server_count == 4
    assert result.network.active_server_count == 3
    assert result.repost_reach.known == 10_000
    assert result.repost_reach.known_reposters == 2
    assert result.repost_reach.unknown_reposters == 0
    assert Enum.any?(result.repost_reach.reposters, &(&1.label == "@alice@social.example"))
    social = Enum.find(result.network.nodes, &(&1.host == "social.example"))
    assert social.interactions == 2
    assert social.status == :active
    assert social.active_month == 12_345
    assert social.node_info_checked_at == checked_at
    assert social.sequence == 1
    assert social.elapsed_seconds == 0

    community = Enum.find(result.network.nodes, &(&1.host == "community.example"))
    assert community.interactions == 1
    assert community.status == :active
    assert community.sequence == 2
    assert community.elapsed_seconds == 600

    relay = Enum.find(result.network.nodes, &(&1.host == "relay.example"))
    assert relay.interactions == 0
    assert relay.status == :addressed
    assert relay.sequence == nil
    assert relay.elapsed_seconds == nil
  end
end
