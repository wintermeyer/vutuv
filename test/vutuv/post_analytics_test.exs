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
      received_at: now
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

    assert %{
             host: "community.example",
             interactions: 1,
             status: :active,
             active_month: nil,
             node_info_checked_at: nil,
             repost_potential: 0
           } in result.network.nodes

    assert %{
             host: "relay.example",
             interactions: 0,
             status: :addressed,
             active_month: nil,
             node_info_checked_at: nil,
             repost_potential: 0
           } in result.network.nodes
  end
end
