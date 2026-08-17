defmodule Vutuv.FediverseFeedArrivalTest do
  @moduledoc """
  The nudge an open /feed needs to dot a tab it is not looking at (issue #1503).

  Four writes put a row on the Fediverse side of somebody's timeline — a
  followed account posting or boosting, and a member here passing a cached post
  or a reply on — and none of them told anybody. The point of this file is that
  all four now do, that they say it **once** however often the same activity is
  delivered, and that they say it to the people whose feed the row can actually
  reach.

  What they deliberately do NOT say is whether the reader may see it: that is
  the feed's own question (`Vutuv.Posts.feed_source_since?/3`), because mute,
  follow state, audience and the language filter all answer differently per
  member.

  `async: false` — the inbound cap and the outbound budget live in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Activity
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  @actor "https://social.example/users/them"
  @inbox @actor <> "/inbox"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      name: "Thea Remote",
      inbox_uri: @inbox
    })
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp follow(user, acc, attrs \\ []) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: attrs[:state] || "accepted",
      muted: attrs[:muted] || false,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  defp create_activity(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    object =
      Map.merge(
        %{
          "id" => "https://social.example/posts/#{unique}",
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "<p>Frisch von drüben.</p>",
          "url" => "https://social.example/@them/#{unique}",
          "published" => DateTime.to_iso8601(DateTime.utc_now(:second)),
          "to" => [@public]
        },
        overrides
      )

    %{"type" => "Create", "actor" => @actor, "object" => object}
  end

  defp announce(object_url) do
    %{
      "id" => @actor <> "#announces/#{System.unique_integer([:positive])}",
      "type" => "Announce",
      "actor" => @actor,
      "published" => DateTime.to_iso8601(DateTime.utc_now(:second)),
      "object" => object_url
    }
  end

  defp cached_post do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: account().id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: "Lesenswert.",
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp note do
    now = DateTime.utc_now(:second)

    Repo.insert!(%Note{
      post_id: insert(:post, user: insert(:activated_user)).id,
      object_uri: "https://social.example/n/#{System.unique_integer([:positive])}",
      actor_uri: @actor,
      origin_url: "https://social.example/@them/1",
      handle: "them",
      display_name: "Thea Remote",
      content_text: "Eine Antwort von drüben.",
      audience: "public",
      inbox_uri: @inbox,
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  describe "what a followed account writes" do
    test "a post reaches the local followers' open feeds" do
      acc = account()
      reader = insert(:activated_user)
      follow(reader, acc)
      Activity.subscribe(reader.id)

      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert_receive {:remote_feed_arrival, %{at: %NaiveDateTime{}}}
    end

    test "the stamp is the post's own publication time, not the delivery's" do
      # The feed compares it against the newest row it can already see, so it
      # has to be the stamp that row would carry in the merged timeline.
      acc = account()
      reader = insert(:activated_user)
      follow(reader, acc)
      Activity.subscribe(reader.id)

      published = "2026-07-20T09:00:00Z"

      assert :ok =
               Fediverse.record_remote_post(create_activity(%{"published" => published}), @actor)

      assert_receive {:remote_feed_arrival, %{at: at}}
      assert at == ~N[2026-07-20 09:00:00]
    end

    test "a redelivery says nothing — it is one post arriving once per follower" do
      acc = account()
      reader = insert(:activated_user)
      follow(reader, acc)
      Activity.subscribe(reader.id)

      activity = create_activity()
      assert :ok = Fediverse.record_remote_post(activity, @actor)
      assert_receive {:remote_feed_arrival, _}

      assert :skip = Fediverse.record_remote_post(activity, @actor)
      refute_receive {:remote_feed_arrival, _}
    end

    test "a muted follow is left alone" do
      # The one per-member gate the fan-out can answer itself: it hangs off the
      # very follow row being joined, so a muted reader pays neither the message
      # nor the query behind it.
      acc = account()
      reader = insert(:activated_user)
      follow(reader, acc, muted: true)
      Activity.subscribe(reader.id)

      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)

      refute_receive {:remote_feed_arrival, _}
    end

    test "a boost reaches them too, and only once" do
      acc = account()
      reader = insert(:activated_user)
      follow(reader, acc)
      author = federating_member()
      {:ok, post} = Posts.create_post(author, %{body: "Von hier."})
      url = "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"

      Activity.subscribe(reader.id)
      assert :ok = Fediverse.record_remote_boost(announce(url), @actor)
      assert_receive {:remote_feed_arrival, %{at: %NaiveDateTime{}}}

      # A second `Announce` of the same post collides with the row already
      # there. `DO NOTHING` cannot report that, which is why the boost path
      # reads the row back before it says anything.
      assert :ok = Fediverse.record_remote_boost(announce(url), @actor)
      refute_receive {:remote_feed_arrival, _}
    end

    test "a follow still merely requested hears nothing about a boost" do
      # `feed_remote_boosts/4` shows a boost only on an accepted follow, so a
      # nudge on a requested one could never lead anywhere. Somebody else's
      # accepted follow is what gets the boost recorded at all.
      acc = account()
      follow(insert(:activated_user), acc)
      waiting = insert(:activated_user)
      follow(waiting, acc, state: "requested")
      author = federating_member()
      {:ok, post} = Posts.create_post(author, %{body: "Von hier."})

      Activity.subscribe(waiting.id)

      assert :ok =
               Fediverse.record_remote_boost(
                 announce("#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"),
                 @actor
               )

      refute_receive {:remote_feed_arrival, _}
    end
  end

  describe "what a member here passes on" do
    test "resharing a cached post tells their followers and themselves" do
      sharer = federating_member()
      reader = insert(:activated_user)
      Vutuv.Social.follow(reader, sharer.id)

      Activity.subscribe(reader.id)
      Activity.subscribe(sharer.id)

      assert {:ok, :reposted} = Fediverse.repost_remote_post(sharer, cached_post())

      assert_receive {:remote_feed_arrival, %{at: %NaiveDateTime{}}}
      assert_receive {:remote_feed_arrival, %{at: %NaiveDateTime{}}}
    end

    test "resharing a reply does the same" do
      sharer = federating_member()
      reader = insert(:activated_user)
      Vutuv.Social.follow(reader, sharer.id)
      Activity.subscribe(reader.id)

      assert {:ok, :reposted} = Fediverse.repost_note(sharer, note())

      assert_receive {:remote_feed_arrival, %{at: %NaiveDateTime{}}}
    end

    test "the stamp never lands after the row it points at" do
      # Read before the write on purpose: the feed asks its sources for a row at
      # or after this moment, and a stamp taken afterwards can sit a tick past
      # the very row it is meant to find.
      sharer = federating_member()
      Activity.subscribe(sharer.id)

      assert {:ok, :reposted} = Fediverse.repost_remote_post(sharer, cached_post())

      assert_receive {:remote_feed_arrival, %{at: at}}
      [entry] = Fediverse.feed_remote_reposts(sharer, 1, nil)
      assert NaiveDateTime.compare(entry.at, at) != :lt
    end

    test "a second tab pressing the same button says nothing" do
      sharer = federating_member()
      post = cached_post()
      assert {:ok, :reposted} = Fediverse.repost_remote_post(sharer, post)

      Activity.subscribe(sharer.id)
      assert {:ok, :already} = Fediverse.repost_remote_post(sharer, post)

      refute_receive {:remote_feed_arrival, _}
    end

    test "a muted follower is left alone" do
      sharer = federating_member()
      reader = insert(:activated_user)
      Vutuv.Social.follow(reader, sharer.id)
      edge = Vutuv.Social.follow_edge(reader.id, sharer.id)
      Vutuv.Social.toggle_follow_mute!(reader.id, edge.id)

      Activity.subscribe(reader.id)
      assert {:ok, :reposted} = Fediverse.repost_remote_post(sharer, cached_post())

      refute_receive {:remote_feed_arrival, _}
    end

    test "a heart is not a feed row and sends nothing" do
      sharer = federating_member()
      Activity.subscribe(sharer.id)

      assert {:ok, :liked} = Fediverse.like_remote_post(sharer, cached_post())

      refute_receive {:remote_feed_arrival, _}
    end
  end
end
