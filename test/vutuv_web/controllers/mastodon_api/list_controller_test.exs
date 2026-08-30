defmodule VutuvWeb.MastodonApi.ListControllerTest do
  @moduledoc """
  The lists behind a client's own tabs. Setting a bookmark worked before this;
  finding it again did not.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Social

  @mastodon_host "mastodon.localhost"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  test "what you bookmarked and what you liked come back", %{conn: conn} do
    member = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, saved} = Posts.create_post(author, %{body: "Zum Merken"})
    {:ok, liked} = Posts.create_post(author, %{body: "Gefällt mir"})

    :ok = Posts.bookmark_post(member, saved)
    :ok = Posts.like_post(member, liked)

    token = mastodon_token(member, ["read"])

    bookmarks = conn |> mastodon_conn(token) |> get("/api/v1/bookmarks") |> json_response(200)
    assert Enum.map(bookmarks, & &1["id"]) == [saved.id]

    favourites =
      build_conn() |> mastodon_conn(token) |> get("/api/v1/favourites") |> json_response(200)

    assert Enum.map(favourites, & &1["id"]) == [liked.id]
  end

  # Issue #1597. Saving or liking something from another network answers 200
  # (#1588) — and then the list it went into has to hold it, or the client shows
  # the act as done and the thing as gone, which reads as data loss rather than
  # as a missing feature.
  describe "the lists hold what came from another network" do
    test "a cached post and a cached reply are in /bookmarks", %{conn: conn} do
      member = insert(:activated_user)
      author = insert(:activated_user)
      {:ok, own} = Posts.create_post(author, %{body: "Von hier"})
      account = remote_account()
      remote = cached_post(account)
      reply = insert(:note, actor_uri: account.actor_uri)

      :ok = Posts.bookmark_post(member, own)
      assert {:ok, :bookmarked} = Fediverse.bookmark_remote_post(member, remote)
      assert {:ok, :bookmarked} = Fediverse.bookmark_note(member, reply)

      statuses =
        conn
        |> mastodon_conn(mastodon_token(member, ["read"]))
        |> get("/api/v1/bookmarks")
        |> json_response(200)

      ids = Enum.map(statuses, & &1["id"])
      assert own.id in ids
      assert ("remote-" <> remote.id) in ids
      assert ("remote-note-" <> reply.id) in ids

      # Read through `notes_with_account/0` like every other loader of a reply,
      # so its author is the account this installation holds rather than the
      # stand-in a stranger gets — one reply, one identity, whichever list it
      # was reached from.
      saved_reply = Enum.find(statuses, &(&1["id"] == "remote-note-" <> reply.id))
      assert saved_reply["account"]["id"] == "remote-" <> account.id
    end

    test "a cached post and a cached reply are in /favourites", %{conn: conn} do
      member = federating_member()
      author = insert(:activated_user)
      {:ok, own} = Posts.create_post(author, %{body: "Von hier"})
      remote = cached_post(remote_account())
      reply = insert(:note)

      :ok = Posts.like_post(member, own)
      assert {:ok, :liked} = Fediverse.like_remote_post(member, remote)
      assert {:ok, :liked} = Fediverse.like_note(member, reply)

      ids =
        conn
        |> mastodon_conn(mastodon_token(member, ["read"]))
        |> get("/api/v1/favourites")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert own.id in ids
      assert ("remote-" <> remote.id) in ids
      assert ("remote-note-" <> reply.id) in ids
    end

    # The boundary a client hands back is the id it was given, and for anything
    # from another network that is `remote-<uuid>`. Without the strip it casts
    # to nil, a nil boundary is no boundary, and no boundary is the newest page
    # — so "load more" serves the same page for ever.
    test "walking past a remote bookmark reaches the older ones", %{conn: conn} do
      member = insert(:activated_user)
      author = insert(:activated_user)
      {:ok, older} = Posts.create_post(author, %{body: "Älter"})
      remote = cached_post(remote_account())

      :ok = Posts.bookmark_post(member, older)
      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(member, remote)

      ids =
        conn
        |> mastodon_conn(mastodon_token(member, ["read"]))
        |> get("/api/v1/bookmarks", %{"max_id" => "remote-" <> remote.id})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert ids == [older.id]
    end

    # `min_id` asks for what is newer than the boundary and answers with the
    # OLDEST of those, so a client can walk forward. `Keyset.take_page/2` is now
    # the only place that rule lives, for this list and for the public timeline
    # both — and a merged list is where losing it would hide: four entries, a
    # limit of two, and taking the tail against taking the head give different
    # pages. Without this, dropping the branch serves the newest page for ever
    # while the whole suite stays green.
    test "min_id over a merged list answers the oldest above the boundary", %{conn: conn} do
      member = insert(:activated_user)
      author = insert(:activated_user)

      {:ok, oldest} = Posts.create_post(author, %{body: "Eins"})
      remote = cached_post(remote_account())
      {:ok, third} = Posts.create_post(author, %{body: "Drei"})
      {:ok, newest} = Posts.create_post(author, %{body: "Vier"})

      :ok = Posts.bookmark_post(member, oldest)
      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(member, remote)
      :ok = Posts.bookmark_post(member, third)
      :ok = Posts.bookmark_post(member, newest)

      ids =
        conn
        |> mastodon_conn(mastodon_token(member, ["read"]))
        |> get("/api/v1/bookmarks", %{"min_id" => oldest.id, "limit" => "2"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      # Newest-first within the page, but the page itself is the two entries
      # sitting just above the boundary — not the two newest of the four.
      assert ids == [third.id, "remote-" <> remote.id]
      refute newest.id in ids
    end

    # The other half of the same strip: the `Link` header names the boundary by
    # comparing the ids on the page, and a prefixed id sorts by its prefix — so
    # the oldest entry on a mixed page is not the one a raw comparison picks,
    # and the next page repeats what the client already has.
    test "the next link names the oldest entry even when it is a remote one", %{conn: conn} do
      member = insert(:activated_user)
      author = insert(:activated_user)
      remote = cached_post(remote_account())
      {:ok, newer} = Posts.create_post(author, %{body: "Neuer"})

      {:ok, :bookmarked} = Fediverse.bookmark_remote_post(member, remote)
      :ok = Posts.bookmark_post(member, newer)

      conn =
        conn
        |> mastodon_conn(mastodon_token(member, ["read"]))
        |> get("/api/v1/bookmarks", %{"limit" => "2"})

      assert [link] = Plug.Conn.get_resp_header(conn, "link")
      assert [_next, _prev] = String.split(link, ", ")
      assert link =~ "max_id=#{remote.id}"
      refute link =~ "max_id=#{newer.id}"
    end
  end

  test "the follower list", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])

    accounts =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/accounts/#{member.id}/followers")
      |> json_response(200)

    assert Enum.map(accounts, & &1["id"]) == [follower.id]
  end

  test "blocked and muted members are listed", %{conn: conn} do
    member = insert(:activated_user)
    blocked = insert(:activated_user)
    muted = insert(:activated_user)

    {:ok, _} = Social.block_user(member, blocked)
    {:ok, _} = Social.follow(member, muted.id)
    Social.set_follow_mute(member, muted, true)

    token = mastodon_token(member, ["read"])

    blocks = conn |> mastodon_conn(token) |> get("/api/v1/blocks") |> json_response(200)
    assert Enum.map(blocks, & &1["id"]) == [blocked.id]

    mutes = build_conn() |> mastodon_conn(token) |> get("/api/v1/mutes") |> json_response(200)
    assert Enum.map(mutes, & &1["id"]) == [muted.id]
  end

  test "who liked and who reposted a status", %{conn: conn} do
    author = insert(:activated_user)
    liker = insert(:activated_user)
    reposter = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Reaktionen"})
    :ok = Posts.like_post(liker, post)
    :ok = Posts.repost_post(reposter, post)

    token = mastodon_token(insert(:activated_user), ["read"])

    liked_by =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/statuses/#{post.id}/favourited_by")
      |> json_response(200)

    assert Enum.map(liked_by, & &1["id"]) == [liker.id]

    reblogged_by =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/statuses/#{post.id}/reblogged_by")
      |> json_response(200)

    assert Enum.map(reblogged_by, & &1["id"]) == [reposter.id]
  end

  # Naming who engaged with a post the asker cannot read would be a roundabout
  # way of reading a restricted audience.
  test "who reacted is not answerable for a status you cannot see", %{conn: conn} do
    author = insert(:activated_user)
    stranger = insert(:activated_user)

    {:ok, private} =
      Posts.create_post(author, %{
        body: "Nur für Follower",
        denials: [%{wildcard: "non_followers"}]
      })

    token = mastodon_token(stranger, ["read"])

    assert conn
           |> mastodon_conn(token)
           |> get("/api/v1/statuses/#{private.id}/favourited_by")
           |> response(404)
  end

  test "the public timeline lists site-feed posts", %{conn: conn} do
    author = insert(:activated_user, noindex?: false, noai?: false)
    {:ok, post} = Posts.create_post(author, %{body: "Für die Allgemeinheit"})

    token = mastodon_token(insert(:activated_user), ["read"])

    statuses =
      conn |> mastodon_conn(token) |> get("/api/v1/timelines/public") |> json_response(200)

    assert Enum.any?(statuses, &(&1["id"] == post.id))
  end

  # The site feed lists only members who opted out of nothing, and the public
  # timeline inherits that rather than inventing a wider firehose.
  test "a member who opted out of aggregation stays out of the public timeline", %{conn: conn} do
    author = insert(:activated_user, noindex?: true)
    {:ok, post} = Posts.create_post(author, %{body: "Nicht im Aggregat"})

    token = mastodon_token(insert(:activated_user), ["read"])

    statuses =
      conn |> mastodon_conn(token) |> get("/api/v1/timelines/public") |> json_response(200)

    refute Enum.any?(statuses, &(&1["id"] == post.id))
  end

  test "a hashtag timeline answers its posts, an unknown tag an empty list", %{conn: conn} do
    author = insert(:activated_user)
    tag = insert(:tag)
    {:ok, post} = Posts.create_post(author, %{body: "Zum Thema ##{tag.slug}"})

    token = mastodon_token(insert(:activated_user), ["read"])

    statuses =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/timelines/tag/#{tag.slug}")
      |> json_response(200)

    assert Enum.any?(statuses, &(&1["id"] == post.id))

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/timelines/tag/gibtesnicht")
           |> json_response(200) == []
  end

  test "custom emojis answer an empty list without a token", %{conn: conn} do
    assert conn
           |> Map.put(:host, @mastodon_host)
           |> get("/api/v1/custom_emojis")
           |> json_response(200) == []
  end
end
