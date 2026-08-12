defmodule Vutuv.FediversePostRepostsTest do
  @moduledoc """
  Sharing a post from another network onward (issue #1166): what is stored, what
  leaves the building, who sees it, and the retention bargain — a reposted copy
  outlives the six-month ceiling, but only while its original is still published.

  `async: false` — the outbound budget lives in the shared `Vutuv.RateLimiter`
  ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  @actor "https://social.example/users/them"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(attrs \\ []) do
    Repo.insert!(%RemoteAccount{
      actor_uri: attrs[:actor_uri] || @actor,
      host: attrs[:host] || "social.example",
      handle: "them",
      inbox_uri: (attrs[:actor_uri] || @actor) <> "/inbox"
    })
  end

  defp cached_post(acc, audience \\ "public") do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: acc.id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: "Lesenswert.",
      audience: audience,
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp follow(user, acc, state \\ "accepted") do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  # The origin answering "still here", as an ActivityPub Note.
  defp serve_note(%RemotePost{} = post, overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "id" => post.object_uri,
          "type" => "Note",
          "content" => "<p>Lesenswert.</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        overrides
      )

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(doc))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp queued do
    Repo.all(from(d in Delivery, order_by: [asc: d.id]))
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "resharing" do
    setup do
      %{user: federating_member(), post: cached_post(account())}
    end

    test "stores the row and queues a public Announce", ctx do
      assert {:ok, :reposted} = Fediverse.repost_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostRepost, :count) == 1

      assert [%{"type" => "Announce"} = announce] = queued()
      assert announce["object"] == ctx.post.object_uri
      # Public addressing, unlike the Like beside it: a boost *is* publishing.
      assert "https://www.w3.org/ns/activitystreams#Public" in announce["to"]
      # And the author learns of it.
      assert @actor in announce["cc"]
    end

    test "resharing twice is one row and one activity", ctx do
      assert {:ok, :reposted} = Fediverse.repost_remote_post(ctx.user, ctx.post)
      assert {:ok, :already} = Fediverse.repost_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostRepost, :count) == 1
      assert length(queued()) == 1
    end

    test "taking it back queues the matching Undo", ctx do
      {:ok, :reposted} = Fediverse.repost_remote_post(ctx.user, ctx.post)

      assert {:ok, :unreposted} = Fediverse.unrepost_remote_post(ctx.user, ctx.post)

      assert Repo.aggregate(PostRepost, :count) == 0
      assert [%{"id" => announce_id}, %{"type" => "Undo"} = undo] = queued()
      assert undo["object"]["id"] == announce_id
      assert undo["object"]["type"] == "Announce"
    end

    test "the Undo still goes out once the member has stopped federating", ctx do
      {:ok, :reposted} = Fediverse.repost_remote_post(ctx.user, ctx.post)
      user = ctx.user |> Ecto.Changeset.change(fediverse_followers?: false) |> Repo.update!()

      # A withdrawal happens exactly when the state that allowed the original
      # act is already gone (issue #1102).
      assert {:ok, :unreposted} = Fediverse.unrepost_remote_post(user, ctx.post)
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end
  end

  describe "the gates" do
    test "a followers-only post cannot be reshared" do
      user = federating_member()
      acc = account()
      follow(user, acc)
      post = cached_post(acc, "followers")

      # Passing on an audience its author narrowed is not ours to do, and a
      # boost is the least reversible way to do it.
      assert {:error, :post_not_public} = Fediverse.check_remote_repost(user, post)
      assert {:error, :post_not_public} = Fediverse.repost_remote_post(user, post)
      assert queued() == []
    end

    test "a member who does not federate is told which refusal it is" do
      user = insert(:activated_user)

      assert {:error, :not_federating} =
               Fediverse.repost_remote_post(user, cached_post(account()))
    end

    test "a post deleted meanwhile is an answer, not a crash" do
      user = federating_member()
      post = cached_post(account())
      Repo.delete!(post)

      assert {:error, :not_found} = Fediverse.repost_remote_post(user, post)
      assert Repo.aggregate(PostRepost, :count) == 0
    end

    test "the hourly budget refuses past the limit, and leaves no row behind" do
      Application.put_env(:vutuv, :fediverse_outbound_boost_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_outbound_boost_limit) end)

      user = federating_member()
      acc = account()
      {:ok, :reposted} = Fediverse.repost_remote_post(user, cached_post(acc))

      assert {:error, :boost_capped} = Fediverse.repost_remote_post(user, cached_post(acc))
      # A boost painted that never left would be the one disagreement the
      # member cannot fix from here.
      assert Repo.aggregate(PostRepost, :count) == 1
    end
  end

  describe "the feed" do
    test "a reshare reaches the followers of the member who shared it" do
      sharer = federating_member()
      reader = insert(:activated_user)
      Vutuv.Social.follow(reader, sharer.id)

      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(sharer, post)

      # The reader follows nobody on another network at all — this is the one
      # way that content reaches them.
      assert [entry] = Posts.feed_page(reader).entries
      assert entry.remote_post.id == post.id
      assert entry.reposted_by.id == sharer.id
    end

    test "a muted follow keeps its reshares out, like everything else" do
      sharer = federating_member()
      reader = insert(:activated_user)
      {:ok, follow} = Vutuv.Social.follow(reader, sharer.id)
      Vutuv.Social.toggle_follow_mute!(reader.id, follow.id)

      {:ok, :reposted} = Fediverse.repost_remote_post(sharer, cached_post(account()))

      assert Posts.feed_page(reader).entries == []
    end
  end

  describe "how loudly the boost speaks" do
    test "an unlisted post is not reshared into public timelines" do
      user = federating_member()
      post = cached_post(account(), "unlisted")

      assert {:ok, :reposted} = Fediverse.repost_remote_post(user, post)

      assert [announce] = queued()
      # Its author put the public collection in `cc`, not `to`, to keep it out
      # of public timelines. Announcing it `to: [Public]` would file the reshare
      # as public on every receiving server — louder than what it boosts.
      refute "https://www.w3.org/ns/activitystreams#Public" in announce["to"]
      assert "https://www.w3.org/ns/activitystreams#Public" in announce["cc"]
    end

    test "a public post is reshared publicly, as it should be" do
      user = federating_member()

      {:ok, :reposted} = Fediverse.repost_remote_post(user, cached_post(account()))

      assert [%{"to" => to}] = queued()
      assert "https://www.w3.org/ns/activitystreams#Public" in to
    end
  end

  describe "when the copy goes away under a standing reshare" do
    setup do
      user = federating_member()
      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(user, post)
      %{user: user, post: post}
    end

    test "a member's report withdraws the boost as well as deleting the copy", ctx do
      assert :ok = Fediverse.report_remote_post(ctx.post.id, insert(:activated_user))

      # The rows cascade; the Announce on other servers does not. Without the
      # withdrawal the reporter's complaint removes it here and leaves the
      # boost standing under somebody's name out there.
      assert Repo.aggregate(PostRepost, :count) == 0
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end

    test "so does the author narrowing it upstream", ctx do
      serve_note(ctx.post, %{"to" => ["https://social.example/users/them/followers"]})

      assert :deleted = Fediverse.refresh_reposted_post(ctx.post)
      assert Enum.any?(queued(), &(&1["type"] == "Undo"))
    end
  end

  describe "the sharer's own timeline" do
    test "a reshare shows on their profile and under the Reposts filter" do
      sharer = federating_member()
      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(sharer, post)

      assert [entry] = Posts.profile_posts(sharer, nil)
      assert entry.remote_post.id == post.id
      assert entry.reposted_by.id == sharer.id

      assert [_] = Posts.profile_posts(sharer, nil, type: :reposts)
      # And not under "own posts": it is not one.
      assert Posts.profile_posts(sharer, nil, type: :posts) == []
    end

    test "it leaves the timeline once its author narrows the audience" do
      sharer = federating_member()
      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(sharer, post)

      Repo.update_all(RemotePost, set: [audience: "followers"])

      # A timeline is a public page, so the audience is re-asked there rather
      # than trusted from the moment the button was pressed.
      assert Posts.profile_posts(sharer, nil) == []
    end
  end

  describe "the retention bargain" do
    setup do
      user = federating_member()
      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(user, post)
      %{user: user, post: post}
    end

    test "a reshared copy survives the ceiling", ctx do
      Repo.update_all(RemotePost, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])

      # Pulling it out from under the people reading it on a calendar rule
      # would be the wrong call while somebody here vouches for it.
      assert Fediverse.expire_due_remote_posts() == 0
      assert Repo.get(RemotePost, ctx.post.id)
    end

    test "and goes at once when the original is gone upstream", ctx do
      Application.put_env(:vutuv, :fediverse_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 410, "") end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)

      assert :deleted = Fediverse.refresh_reposted_post(ctx.post)

      # A repost never keeps alive what its author has already deleted.
      refute Repo.get(RemotePost, ctx.post.id)
      assert Repo.aggregate(PostRepost, :count) == 0
    end

    test "still published pushes the ceiling out", ctx do
      serve_note(ctx.post)

      # The half that makes the exemption above defensible: the copy stays, but
      # only because the origin was asked and answered.
      assert :refreshed = Fediverse.refresh_reposted_post(ctx.post)

      kept = Repo.get!(RemotePost, ctx.post.id)
      assert kept.checked_at
      assert DateTime.compare(kept.expires_at, ctx.post.expires_at) == :gt
    end

    test "the sweeper's batch does the same for everything due", ctx do
      serve_note(ctx.post)

      assert %{refreshed: 1, deleted: 0} = Fediverse.refresh_reposted_posts()

      # And nothing is due a second time straight afterwards.
      assert %{refreshed: 0, deleted: 0} = Fediverse.refresh_reposted_posts()
    end

    test "the author narrowing it upstream deletes the copy too", ctx do
      serve_note(ctx.post, %{"to" => ["https://social.example/users/them/followers"]})

      # Visible to us rather than a 403, but the same "stop showing this".
      assert :deleted = Fediverse.refresh_reposted_post(ctx.post)
      refute Repo.get(RemotePost, ctx.post.id)
    end

    test "but only while the verification is current", ctx do
      # The exemption is a promise that the copy is still wanted AND still
      # published; the second half is only true while somebody keeps asking. A
      # backlog must therefore drain itself, not accumulate forever unverified.
      stale = DateTime.add(DateTime.utc_now(:second), -400 * 86_400)

      Repo.update_all(RemotePost,
        set: [checked_at: stale, received_at: stale, expires_at: stale]
      )

      assert Fediverse.expire_due_remote_posts() == 1
      refute Repo.get(RemotePost, ctx.post.id)
    end

    test "a purge of an unfollowed author's posts spares it too", ctx do
      # The copy's life is tied to the reshare and the original, not to
      # anybody's follow: nobody follows this author here at all.
      assert Fediverse.purge_unfollowed_remote_posts() == 0
      assert Repo.get(RemotePost, ctx.post.id)
    end

    test "a server that simply does not answer changes nothing", ctx do
      Application.put_env(:vutuv, :fediverse_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)

      # An outage must buy neither indefinite retention nor a mass delete.
      assert :skip = Fediverse.refresh_reposted_post(ctx.post)
      assert Repo.get(RemotePost, ctx.post.id)
    end
  end

  describe "the re-verification queue" do
    # A skip that stamps no clock holds the front of every later batch: the due
    # query serves the least recently checked first, and nothing about an
    # unworkable copy changes between two runs. The cap is then spent on work
    # that can never complete, while the copies somebody is actually reading sit
    # behind it and are never reached. `refresh_counts/1` in the same module
    # carries a long note about having shipped exactly this once; these two arms
    # are the same shape, so they get the same guard.

    test "an origin that does not answer does not hold the front of it" do
      user = federating_member()
      post = cached_post(account())
      {:ok, :reposted} = Fediverse.repost_remote_post(user, post)

      Application.put_env(:vutuv, :fediverse_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)

      assert %{skipped: 1} = Fediverse.refresh_reposted_posts()

      # Stamped, so it rejoins the rotation at its own pace instead of being due
      # again immediately. The copy stays: an outage is not a takedown.
      assert %{skipped: 0} = Fediverse.refresh_reposted_posts()
      assert Repo.get(RemotePost, post.id)
    end

    test "and neither does a copy nobody here can sign for" do
      post = cached_post(account())
      user = insert(:activated_user)

      # No keypair, so there is no actor to sign the fetch as — the copy can
      # never be verified until somebody who federates reshares it too.
      Repo.insert!(%PostRepost{user_id: user.id, remote_post_id: post.id})

      assert :skip = Fediverse.refresh_reposted_post(post)
      assert %{skipped: 0} = Fediverse.refresh_reposted_posts()
      assert Repo.get(RemotePost, post.id)
    end
  end
end
