defmodule Vutuv.PostAnalytics.TwelveMonthsTest do
  @moduledoc """
  The investor page's reach over the last 12 months
  (`Vutuv.PostAnalytics.TwelveMonths`): the per-post repost reach of
  `/:slug/posts/:id/analytics`, summed over every public post published from
  the first day of the month eleven months back until now.

  Every timestamp here is fixed and `now` is injected, because the window is a
  date window: a test that reads the real clock would fail at a month's turn.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.PostAnalytics
  alias Vutuv.PostAnalytics.TwelveMonths
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo

  @now ~U[2031-06-15 12:00:00Z]

  defp post!(author, body, published) do
    {:ok, post} = Posts.create_post(author, %{body: body})

    Post
    |> where([p], p.id == ^post.id)
    |> Repo.update_all(set: [inserted_at: published])

    %{post | inserted_at: published}
  end

  defp announce!(post, actor_uri, received_at) do
    Repo.insert!(%Reaction{
      post_id: post.id,
      actor_uri: actor_uri,
      kind: "announce",
      received_at: received_at
    })
  end

  setup do
    author = insert(:activated_user)
    reposter = insert(:activated_user)
    liker = insert(:activated_user)

    # The reposter's audience here: three members.
    for _ <- 1..3, do: follow!(insert(:activated_user), reposter)

    march = post!(author, "Published in March", ~N[2031-03-02 09:00:00])
    may = post!(author, "Published in May", ~N[2031-05-20 18:00:00])
    too_old = post!(author, "Published before the window", ~N[2030-06-30 23:30:00])
    hidden = post!(author, "Only for some", ~N[2031-04-01 08:00:00])
    Repo.insert!(%PostDenial{post_id: hidden.id, wildcard: "everyone"})

    for post <- [march, may] do
      Repo.insert!(%PostRepost{
        post_id: post.id,
        user_id: reposter.id,
        inserted_at: ~N[2031-05-21 10:00:00]
      })
    end

    Repo.insert!(%PostLike{
      post_id: march.id,
      user_id: liker.id,
      inserted_at: ~N[2031-03-03 10:00:00]
    })

    Repo.insert!(%RemoteAccount{
      actor_uri: "https://social.example/users/alice",
      host: "social.example",
      handle: "alice",
      inbox_uri: "https://social.example/users/alice/inbox",
      follower_count: 10_000,
      follower_count_checked_at: ~U[2031-06-01 00:00:00Z]
    })

    announce!(march, "https://social.example/users/alice", ~U[2031-03-02 10:00:00Z])
    # No stored follower total: counted as a reposter, not as audience.
    announce!(may, "https://other.example/users/bob", ~U[2031-05-20 19:00:00Z])
    # Neither of these belongs to the window's public posts.
    announce!(too_old, "https://social.example/users/alice", ~U[2030-07-01 10:00:00Z])
    announce!(hidden, "https://social.example/users/alice", ~U[2031-04-01 09:00:00Z])

    Repo.insert!(%Reaction{
      post_id: may.id,
      actor_uri: "https://community.example/people/carol",
      kind: "like",
      received_at: ~U[2031-05-20 20:00:00Z]
    })

    %{march: march, may: may}
  end

  test "sums the known repost audience of every public post of the last 12 months" do
    result = TwelveMonths.compute(now: @now)

    assert result.since == ~D[2030-07-01]
    assert result.posts == 2
    # The member who reposted both posts counts once per post, like the
    # per-post pages it adds up.
    assert %{followers: 6, reposts: 2} = Enum.find(result.steps, &(&1.key == :local_reposts))
    assert %{followers: 10_000} = Enum.find(result.steps, &(&1.key == :remote_reposts))
    assert result.reach.known == 10_006
    assert result.reach.reposts == 4
    assert result.reach.known_reposters == 3
    assert result.reach.unknown_reposters == 1
    assert result.totals == %{likes: 2, reposts: 4, replies: 0, all: 6}
    assert result.servers.responded == 3
  end

  test "equals the sum of the per-post reach analyses", %{march: march, may: may} do
    per_post =
      [march, may]
      |> Enum.map(&PostAnalytics.for_post(&1, now: @now).repost_reach.known)
      |> Enum.sum()

    assert per_post == 10_006
    assert TwelveMonths.compute(now: @now).reach.known == per_post
  end

  test "attributes the reach to the month each post was published" do
    months = TwelveMonths.compute(now: @now).months

    # July 2030 to June 2031: twelve months, the current one included.
    assert Enum.map(months, &{&1.year, &1.month}) ==
             Enum.map(7..12, &{2030, &1}) ++ Enum.map(1..6, &{2031, &1})

    assert %{posts: 1, reach: 10_003} = Enum.find(months, &(&1.month == 3))
    assert %{posts: 1, reach: 3} = Enum.find(months, &(&1.month == 5))
    assert %{posts: 0, reach: 0} = Enum.find(months, &(&1.month == 4))
  end

  test "reports every step in order, with what it found and how long it took" do
    parent = self()
    result = TwelveMonths.compute(now: @now, progress: &send(parent, {:step, &1}))

    for key <- TwelveMonths.steps() do
      assert_received {:step, %{key: ^key, ms: ms}} when is_integer(ms) and ms >= 0
    end

    assert Enum.map(result.steps, & &1.key) == TwelveMonths.steps()
    assert %{key: :posts, count: 2} = Enum.find(result.steps, &(&1.key == :posts))

    assert %{key: :remote_reposts, reposts: 2, followers: 10_000, unknown: 1} =
             Enum.find(result.steps, &(&1.key == :remote_reposts))
  end

  test "an empty window still adds up to zero, across a turn of the year" do
    result = TwelveMonths.compute(now: ~U[2035-02-01 00:00:00Z])

    assert result.since == ~D[2034-03-01]
    assert result.posts == 0
    assert result.reach.known == 0
    assert result.totals.all == 0
    assert Enum.map(result.months, & &1.month) == Enum.to_list(3..12) ++ [1, 2]
  end
end
