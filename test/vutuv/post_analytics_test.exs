defmodule Vutuv.PostAnalyticsTest do
  use Vutuv.DataCase

  alias Vutuv.PostAnalytics
  alias Vutuv.Posts
  alias Vutuv.Repo

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
end
