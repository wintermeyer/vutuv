defmodule Vutuv.FediversePastFollowsTest do
  @moduledoc """
  Unfollowing an account on another network stops the future without erasing the
  past (issue #1673) — the fediverse half of `feed_past_follows_test.exs`.

  Two things had to change for it, and both are covered here. The feed reads the
  *current* follow set, so an unfollow used to take the account's whole back
  catalogue with it; and a cached copy of a stranger's post is only held here
  while somebody follows its author, so the unfollow **deleted** those copies
  outright. A span in `fediverse_past_follows` answers both: it is what the two
  remote feed sources read, and it is a hold against the purge.

  Every test places its posts against an explicit span rather than trusting
  wall-clock ordering: the follow's `inserted_at`, the span's `ended_at` and a
  post's `published_at` all have **second** resolution, so a test that just
  follows, posts and unfollows puts all three in the same second and proves
  nothing about the boundaries.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PastFollow
  alias Vutuv.Fediverse.PostRepost
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.PostsHelpers

  defp member, do: insert(:activated_user, fediverse_followers?: true)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds)

  defp account(handle), do: remote_account(handle: handle)

  defp follow(user, account, attrs \\ []) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: attrs[:state] || "accepted",
      muted: attrs[:muted] || false,
      follow_activity_id:
        "https://vutuv.test/#{user.id}/actor#f/#{account.id}/#{System.unique_integer([:positive])}"
    })
  end

  defp post(account, text, seconds_ago, audience \\ "public"),
    do:
      cached_post(account,
        content_text: text,
        audience: audience,
        published_at: ago(seconds_ago)
      )

  # Follows and unfollows for real, then moves both ends of the recorded span,
  # so the test can put posts cleanly before, inside and after it. The member
  # twin is `Vutuv.PostsHelpers.followed_between!/4`.
  defp followed_remote_between!(user, account, started_ago, ended_ago) do
    started_at = ago(started_ago)
    row = follow(user, account)

    {1, nil} =
      Repo.update_all(from(f in Follow, where: f.id == ^row.id),
        set: [inserted_at: DateTime.to_naive(started_at)]
      )

    :ok = Fediverse.unfollow_remote(user, row.id)

    # Scoped to the span this call just wrote (its start is the follow's), so a
    # test can lay down two spells of following without the second rewriting
    # the first.
    {1, nil} =
      Repo.update_all(
        from(w in PastFollow,
          where: w.user_id == ^user.id and w.remote_account_id == ^account.id,
          where: w.started_at == ^started_at
        ),
        set: [ended_at: ago(ended_ago)]
      )

    :ok
  end

  defp feed_texts(user),
    do: user |> Fediverse.feed_remote_posts(20, nil) |> Enum.map(& &1.remote_post.content_text)

  defp spans(user), do: Repo.all(from(w in PastFollow, where: w.user_id == ^user.id))

  describe "recording the span" do
    test "an unfollow records when the follow began and when it ended" do
      user = member()
      them = account("alpha")
      row = follow(user, them)

      :ok = Fediverse.unfollow_remote(user, row.id)

      assert [%PastFollow{} = span] = spans(user)
      assert span.remote_account_id == them.id
      assert span.started_at == DateTime.from_naive!(row.inserted_at, "Etc/UTC")
      assert DateTime.diff(DateTime.utc_now(), span.ended_at) < 5
    end

    test "a muted follow records nothing, so unfollowing cannot undo the mute" do
      user = member()
      them = account("muted")
      row = follow(user, them, muted: true)

      :ok = Fediverse.unfollow_remote(user, row.id)

      assert spans(user) == []
    end

    test "a page's unfollow records nothing: only members have a feed" do
      page = insert(:organization)
      them = account("page-follows")

      row =
        Repo.insert!(%Follow{
          organization_id: page.id,
          remote_account_id: them.id,
          state: "accepted",
          follow_activity_id: "https://vutuv.test/#{page.id}/actor#f/#{them.id}"
        })

      :ok = Fediverse.unfollow_remote(page, row.id)

      assert Repo.aggregate(PastFollow, :count) == 0
    end

    test "leaving the fediverse takes the member's spans with it" do
      user = member()
      them = account("gone")
      :ok = followed_remote_between!(user, them, 600, 300)
      assert [_] = spans(user)

      Fediverse.drop_remote_follows(user)

      assert spans(user) == []
    end
  end

  describe "what the feed still shows" do
    test "posts from inside the span stay, newer and older ones do not" do
      user = member()
      them = account("beta")
      post(them, "before the follow", 900)
      post(them, "while I followed", 450)
      post(them, "after I left", 60)

      :ok = followed_remote_between!(user, them, 600, 300)

      assert feed_texts(user) == ["while I followed"]
    end

    test "a followers-only post from inside the span drops out with the follow" do
      user = member()
      them = account("gamma")
      post(them, "public, from inside", 450)
      post(them, "followers only, from inside", 440, "followers")

      :ok = followed_remote_between!(user, them, 600, 300)

      assert feed_texts(user) == ["public, from inside"]
    end

    # Green with and without the span, and deliberately so: what enforces it is
    # the accepted-follow branch, which carries no time bound at all. It is here
    # to catch the day somebody narrows that branch to "since the follow began"
    # and quietly makes a span the only way to see anything older.
    test "following again shows everything since, spans and all" do
      user = member()
      them = account("delta")
      post(them, "while I followed", 450)
      post(them, "in between", 200)

      :ok = followed_remote_between!(user, them, 600, 300)
      follow(user, them)
      post(them, "since I came back", 10)

      assert feed_texts(user) == ["since I came back", "in between", "while I followed"]
    end

    test "muting the account again keeps its past out too" do
      user = member()
      them = account("epsilon")
      post(them, "while I followed", 450)

      :ok = followed_remote_between!(user, them, 600, 300)
      follow(user, them, muted: true)

      assert feed_texts(user) == []
    end

    test "a boost announced during the span stays, a later one does not" do
      user = member()
      them = account("zeta")
      boost(them, boostable_post("shared while I followed"), announced_at: ago(450))
      boost(them, boostable_post("shared after I left"), announced_at: ago(60))

      :ok = followed_remote_between!(user, them, 600, 300)

      assert boosted_bodies(user) == ["shared while I followed"]
    end
  end

  describe "the cached copies" do
    test "unfollowing keeps the copies from inside the span and drops the rest" do
      user = member()
      them = account("eta")
      earlier = post(them, "before the follow", 900)
      inside = post(them, "while I followed", 450)

      :ok = followed_remote_between!(user, them, 600, 300)

      assert Repo.get(RemotePost, inside.id)
      refute Repo.get(RemotePost, earlier.id)
    end

    test "the hourly sweep leaves a spanned copy alone" do
      user = member()
      them = account("theta")
      inside = post(them, "while I followed", 450)

      :ok = followed_remote_between!(user, them, 600, 300)

      assert Fediverse.purge_unfollowed_remote_posts() == 0
      assert Repo.get(RemotePost, inside.id)
    end

    test "the span buys no extra time: the ceiling still takes the copy" do
      user = member()
      them = account("iota")
      inside = post(them, "while I followed", 450)
      :ok = followed_remote_between!(user, them, 600, 300)

      Repo.update_all(from(p in RemotePost, where: p.id == ^inside.id),
        set: [expires_at: ago(60)]
      )

      assert Fediverse.expire_due_remote_posts() == 1
      refute Repo.get(RemotePost, inside.id)
    end

    test "leaving the fediverse drops the copies the spans were holding" do
      user = member()
      them = account("kappa")
      inside = post(them, "while I followed", 450)
      :ok = followed_remote_between!(user, them, 600, 300)
      assert Repo.get(RemotePost, inside.id)

      Fediverse.drop_remote_follows(user)

      refute Repo.get(RemotePost, inside.id)
    end
  end

  describe "what a member here passed on" do
    test "a reshare made during the span stays after unfollowing them" do
      user = member()
      resharer = member()
      them = account("lambda")

      reshare!(resharer, post(them, "carried while I followed", 450), 450)
      reshare!(resharer, post(them, "carried after I left", 60), 60)

      :ok = PostsHelpers.followed_between!(user, resharer, 600, 300)

      assert reshared_texts(user) == ["carried while I followed"]
    end
  end

  # A vutuv member's own post, for the boost source: `post_id` boosts need no
  # third server to resolve.
  defp boostable_post(body), do: PostsHelpers.create_post!(federating_member(), %{body: body})

  defp boosted_bodies(user) do
    user
    |> Posts.feed_page(limit: 20)
    |> Map.fetch!(:entries)
    |> Enum.filter(&(&1[:boosted_by] != nil))
    |> Enum.map(& &1.post.body)
  end

  defp reshare!(resharer, remote_post, seconds_ago) do
    row = Repo.insert!(%PostRepost{user_id: resharer.id, remote_post_id: remote_post.id})

    {1, nil} =
      Repo.update_all(from(r in PostRepost, where: r.id == ^row.id),
        set: [inserted_at: DateTime.to_naive(ago(seconds_ago))]
      )

    :ok
  end

  defp reshared_texts(user),
    do: user |> Fediverse.feed_remote_reposts(20, nil) |> Enum.map(& &1.remote_post.content_text)
end
