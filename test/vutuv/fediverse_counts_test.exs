defmodule Vutuv.FediverseCountsTest do
  @moduledoc """
  The origin's own like and repost figures for a cached post or reply (issue
  #1283): what is asked, when it is asked, what is believed, and what a member's
  own press does to the number in front of them.

  `async: false` — the outbound budget the like and repost paths claim lives in
  the shared `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll
  back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(host \\ "social.example") do
    uri = "https://#{host}/users/them#{System.unique_integer([:positive])}"

    Repo.insert!(%RemoteAccount{
      actor_uri: uri,
      host: host,
      handle: "them",
      inbox_uri: uri <> "/inbox"
    })
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp follow(user, acc) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  defp boost(booster, post) do
    Repo.insert!(%PostBoost{
      remote_account_id: booster.id,
      remote_post_id: post.id,
      activity_id: "#{booster.actor_uri}/statuses/#{System.unique_integer([:positive])}/activity",
      announced_at: DateTime.utc_now(:second)
    })
  end

  defp cached_post(acc, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: acc.id,
          object_uri: "https://#{acc.host}/p/#{System.unique_integer([:positive])}",
          content_text: "Lesenswert.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
    |> Repo.preload(:remote_account)
  end

  # A followed account, so `refresh_counts/1` finds somebody to sign as.
  defp followed_post(attrs \\ %{}) do
    acc = account()
    user = federating_member()
    follow(user, acc)
    {cached_post(acc, attrs), user}
  end

  # The origin answering with its object, `likes`/`shares` as given.
  defp serve(doc, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    etag = Keyword.get(opts, :etag)
    seen = Keyword.get(opts, :seen)

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        if seen, do: send(seen, {:asked, Plug.Conn.get_req_header(conn, "if-none-match")})

        conn = if etag, do: Plug.Conn.put_resp_header(conn, "etag", etag), else: conn

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(status, Jason.encode!(doc))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp object(post, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => post.object_uri,
        "type" => "Note",
        "content" => "<p>Lesenswert.</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "likes" => %{"type" => "Collection", "totalItems" => 12},
        "shares" => %{"type" => "Collection", "totalItems" => 3}
      },
      overrides
    )
  end

  describe "asking the origin" do
    test "stores the two figures and the ETag" do
      {post, _user} = followed_post()
      serve(object(post), etag: ~s("abc123"))

      assert :updated = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.likes_count == 12
      assert stored.shares_count == 3
      assert stored.counts_etag == ~s("abc123")
      assert stored.counts_failures == 0
      assert stored.counts_checked_at
    end

    test "the second ask carries If-None-Match and a 304 changes no figure" do
      {post, _user} = followed_post()
      serve(object(post), etag: ~s("v1"))
      assert :updated = Fediverse.refresh_counts(post)

      post = Repo.get!(RemotePost, post.id)
      serve(%{}, status: 304, etag: ~s("v1"), seen: self())

      assert :unchanged = Fediverse.refresh_counts(post)
      assert_received {:asked, [~s("v1")]}

      stored = Repo.get!(RemotePost, post.id)
      assert stored.likes_count == 12
      assert stored.shares_count == 3
    end

    test "an identical answer is not a change, so nothing is broadcast" do
      {post, _user} = followed_post()
      serve(object(post))
      assert :updated = Fediverse.refresh_counts(post)

      Fediverse.subscribe_counts()
      assert :unchanged = Fediverse.refresh_counts(Repo.get!(RemotePost, post.id))
      refute_received {:fediverse_counts, _kind, _id, _counts}
    end

    test "a changed figure reaches every open page" do
      {post, _user} = followed_post()
      serve(object(post))
      assert :updated = Fediverse.refresh_counts(post)

      Fediverse.subscribe_counts()
      serve(object(post, %{"likes" => %{"totalItems" => 40}}))

      assert :updated = Fediverse.refresh_counts(Repo.get!(RemotePost, post.id))
      assert_received {:fediverse_counts, :remote_post, id, %{likes: 40, shares: 3}}
      assert id == post.id
    end

    test "a server that serves no collection leaves the figures null" do
      {post, _user} = followed_post()
      serve(object(post) |> Map.drop(["likes", "shares"]))

      # Not `:updated`: nothing moved, because a `0` is a claim we cannot make.
      assert :unchanged = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert is_nil(stored.likes_count)
      assert is_nil(stored.shares_count)
      # It was still asked, so it takes its place on the ladder.
      assert stored.counts_checked_at
    end

    test "a server that stops serving a collection does not zero what it told us before" do
      {post, _user} = followed_post()
      serve(object(post))
      assert :updated = Fediverse.refresh_counts(post)

      serve(object(post) |> Map.drop(["likes"]))
      assert :unchanged = Fediverse.refresh_counts(Repo.get!(RemotePost, post.id))

      assert Repo.get!(RemotePost, post.id).likes_count == 12
    end

    test "an absurd totalItems is capped rather than raising on the column" do
      {post, _user} = followed_post()
      serve(object(post, %{"likes" => %{"totalItems" => 999_999_999_999_999}}))

      assert :updated = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).likes_count == 1_000_000_000
    end

    test "a 404 is a strike, never a deletion" do
      {post, _user} = followed_post()
      serve(%{}, status: 404)

      assert :failed = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.counts_failures == 1
      # Deleting belongs to the retention paths, which weigh a 403 properly.
      assert stored.content_text == "Lesenswert."
    end

    test "a post nobody follows the author or the booster of is not asked about" do
      post = cached_post(account())
      serve(object(post))

      assert :skip = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).likes_count == nil
    end

    # Nobody here follows the author — the post is in the feed because somebody
    # they do follow re-shared it, and that follower is who we sign as. The
    # dereference that stored the post in the first place already works this
    # way; only the figures on its card did not.
    test "a boosted post is asked about, signed as a follower of the booster" do
      booster = account()
      user = federating_member()
      follow(user, booster)

      post = cached_post(account())
      boost(booster, post)
      serve(object(post))

      assert :updated = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).likes_count == 12
    end

    test "a followers-only post is never asked about" do
      {post, _user} = followed_post(%{audience: "followers"})
      serve(object(post))

      assert :skip = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).likes_count == nil
    end

    # The starvation this pair guards against ran on production for days: the
    # skipped objects hold the front of the queue for good, the batch cap is
    # spent on them, and the posts somebody is reading right now — stamped on
    # arrival, so last in the queue — are never reached.
    test "a skipped object rejoins the ladder instead of standing at the head of the queue" do
      post = cached_post(account())
      serve(object(post))

      assert :skip = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.counts_checked_at
      # No strike: the origin did nothing wrong, and a signer can appear the
      # moment somebody here follows the account.
      assert stored.counts_failures == 0
      refute stored.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "an object that can never be asked about does not fill the batch forever" do
      unaskable =
        for _ <- 1..3 do
          post = cached_post(account(), %{published_at: minutes_ago(45)})
          assert :skip = Fediverse.refresh_counts(post)
          post.id
        end

      {fresh, _user} = followed_post(%{counts_checked_at: minutes_ago(6)})

      due = Enum.map(Fediverse.due_for_counts(2), & &1.id)
      assert fresh.id in due
      assert due -- unaskable == due
    end
  end

  describe "the ladder" do
    defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(:second), -minutes * 60)

    test "a post in its first half hour is due five minutes after the last ask" do
      {post, _user} = followed_post(%{counts_checked_at: minutes_ago(6)})

      assert post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "the same post asked about two minutes ago is not due" do
      {post, _user} = followed_post(%{counts_checked_at: minutes_ago(2)})

      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "past the first half hour it drops to every ten minutes" do
      {post, _user} =
        followed_post(%{published_at: minutes_ago(45), counts_checked_at: minutes_ago(6)})

      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [counts_checked_at: minutes_ago(12)]
      )

      assert post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "a day-old post is asked hourly, not every ten minutes" do
      {post, _user} =
        followed_post(%{published_at: minutes_ago(60 * 24), counts_checked_at: minutes_ago(20)})

      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [counts_checked_at: minutes_ago(70)]
      )

      assert post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "a post older than a week has left the ladder for good" do
      {post, _user} =
        followed_post(%{
          published_at: minutes_ago(60 * 24 * 8),
          counts_checked_at: minutes_ago(60 * 24 * 3)
        })

      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "an old post nobody has ever asked about still gets its one ask" do
      # Everything already cached when this shipped is in exactly this state,
      # and without the one-off it would carry no figure for the rest of its six
      # months.
      {post, _user} = followed_post(%{published_at: minutes_ago(60 * 24 * 30)})

      assert post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [counts_checked_at: DateTime.utc_now(:second)]
      )

      # And having been asked once, it leaves the ladder like any other old post.
      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "a never-asked post is due at once, and comes first" do
      {old, _user} = followed_post(%{counts_checked_at: minutes_ago(60)})
      {fresh, _user} = followed_post()

      assert [%{id: first} | _rest] = Fediverse.due_for_counts(10)
      assert first == fresh.id
      assert old.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "the never-asked queue is served newest first" do
      # Everything an installation already holds when this ships has a null
      # here, so the queue starts as one long backfill. Served in creation order
      # it would work through the six-month-old cache first and leave today's
      # posts — the ones somebody is reading — until last.
      {stale, _user} = followed_post(%{published_at: minutes_ago(60 * 24 * 60)})
      {recent, _user} = followed_post(%{published_at: minutes_ago(30)})

      due = Enum.map(Fediverse.due_for_counts(10), & &1.id)

      assert Enum.find_index(due, &(&1 == recent.id)) <
               Enum.find_index(due, &(&1 == stale.id))
    end

    test "failures push the next ask out, and enough of them end it" do
      {post, _user} = followed_post(%{counts_checked_at: minutes_ago(6), counts_failures: 1})

      # One strike doubles the five minutes, so six is no longer enough.
      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [counts_failures: Fediverse.counts_max_strikes()]
      )

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [counts_checked_at: minutes_ago(60 * 24)]
      )

      refute post.id in Enum.map(Fediverse.due_for_counts(10), & &1.id)
    end

    test "no host may fill a whole run" do
      per_host = Fediverse.counts_per_host()
      acc = account("busy.example")
      user = federating_member()
      follow(user, acc)

      for _n <- 1..(per_host + 3), do: cached_post(acc)

      due = Fediverse.due_for_counts(100)
      assert length(due) == per_host
    end

    test "a batch run asks about what is due and tallies the answers" do
      {post, _user} = followed_post()
      serve(object(post))

      assert %{updated: 1} = Fediverse.refresh_due_counts()
      assert Repo.get!(RemotePost, post.id).likes_count == 12
    end
  end

  describe "a reply from another network" do
    defp remote_note(author, attrs \\ %{}) do
      post = insert(:post, user: author)
      now = DateTime.utc_now(:second)

      Repo.insert!(
        struct(
          %Note{
            post_id: post.id,
            object_uri: "https://social.example/n/#{System.unique_integer([:positive])}",
            actor_uri: @actor,
            inbox_uri: @actor <> "/inbox",
            handle: "them",
            content_text: "Danke!",
            audience: "public",
            received_at: now,
            expires_at: DateTime.add(now, 86_400)
          },
          attrs
        )
      )
    end

    test "carries its own figures, signed as the member whose post it answers" do
      author = federating_member()
      note = remote_note(author)
      serve(object(note))

      assert :updated = Fediverse.refresh_counts(note)

      stored = Repo.get!(Note, note.id)
      assert stored.likes_count == 12
      assert stored.shares_count == 3
    end

    test "a reply addressed to the member alone is never asked about" do
      author = federating_member()
      note = remote_note(author, %{audience: "direct"})
      serve(object(note))

      assert :skip = Fediverse.refresh_counts(note)
    end
  end

  describe "the reader's own press" do
    test "a like moves the stored figure at once, and taking it back moves it down" do
      {post, _user} = followed_post(%{likes_count: 12, shares_count: 3})
      member = federating_member()

      assert {:ok, :liked} = Fediverse.like_remote_post(member, post)
      assert Repo.get!(RemotePost, post.id).likes_count == 13

      assert {:ok, :unliked} = Fediverse.unlike_remote_post(member, post)
      assert Repo.get!(RemotePost, post.id).likes_count == 12
    end

    test "a repost moves the shares figure, not the likes" do
      {post, _user} = followed_post(%{likes_count: 12, shares_count: 3})
      member = federating_member()

      assert {:ok, :reposted} = Fediverse.repost_remote_post(member, post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.shares_count == 4
      assert stored.likes_count == 12
    end

    test "a second press writes nothing and moves nothing" do
      {post, _user} = followed_post(%{likes_count: 12})
      member = federating_member()

      assert {:ok, :liked} = Fediverse.like_remote_post(member, post)
      assert {:ok, :already} = Fediverse.like_remote_post(member, post)

      assert Repo.get!(RemotePost, post.id).likes_count == 13
    end

    test "a figure we do not have stays absent rather than becoming one" do
      {post, _user} = followed_post()
      member = federating_member()

      assert {:ok, :liked} = Fediverse.like_remote_post(member, post)
      assert is_nil(Repo.get!(RemotePost, post.id).likes_count)
    end

    test "a bookmark moves nothing at all" do
      {post, _user} = followed_post(%{likes_count: 12, shares_count: 3})
      member = federating_member()

      assert {:ok, :bookmarked} = Fediverse.bookmark_remote_post(member, post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.likes_count == 12
      assert stored.shares_count == 3
    end

    test "the figure never goes below zero" do
      {post, _user} = followed_post(%{likes_count: 0})
      member = federating_member()

      # The origin's answer can land between the like and the unlike and already
      # be back at zero.
      Repo.insert!(%Vutuv.Fediverse.PostLike{user_id: member.id, remote_post_id: post.id})

      assert {:ok, :unliked} = Fediverse.unlike_remote_post(member, post)
      assert Repo.get!(RemotePost, post.id).likes_count == 0
    end

    test "the change reaches every open page" do
      {post, _user} = followed_post(%{likes_count: 12})
      member = federating_member()
      Fediverse.subscribe_counts()

      assert {:ok, :liked} = Fediverse.like_remote_post(member, post)
      assert_received {:fediverse_counts, :remote_post, _id, %{likes: 13}}
    end
  end

  describe "a delivered post" do
    test "carries the figures its own Create announced" do
      acc = account()
      user = federating_member()
      follow(user, acc)

      uri = "https://#{acc.host}/p/#{System.unique_integer([:positive])}"

      assert :ok =
               Fediverse.record_remote_post(
                 %{
                   "type" => "Create",
                   "actor" => acc.actor_uri,
                   "object" => %{
                     "id" => uri,
                     "type" => "Note",
                     "content" => "<p>Frisch.</p>",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "published" => DateTime.to_iso8601(DateTime.utc_now(:second)),
                     "attributedTo" => acc.actor_uri,
                     "likes" => %{"totalItems" => 2},
                     "shares" => %{"totalItems" => 0}
                   }
                 },
                 acc.actor_uri
               )

      stored = Repo.get_by!(RemotePost, object_uri: uri)
      assert stored.likes_count == 2
      assert stored.shares_count == 0
      # It said something, so it starts on the ladder rather than as due now.
      assert stored.counts_checked_at
    end
  end

  test "an installation with the fediverse switched off asks nobody" do
    {post, _user} = followed_post()
    serve(object(post))

    Application.put_env(:vutuv, :fediverse_enabled, false)
    on_exit(fn -> Application.put_env(:vutuv, :fediverse_enabled, true) end)

    assert :skip = Fediverse.refresh_counts(post)
    assert %{updated: 0} = Fediverse.refresh_due_counts()
  end

  test "a member with no keypair cannot be signed as" do
    acc = account()
    user = insert(:activated_user)
    follow(user, acc)
    post = cached_post(acc)
    serve(object(post))

    refute Repo.get_by(Actor, user_id: user.id)
    assert :skip = Fediverse.refresh_counts(post)
  end
end
