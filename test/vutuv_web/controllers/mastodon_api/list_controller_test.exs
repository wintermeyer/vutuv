defmodule VutuvWeb.MastodonApi.ListControllerTest do
  @moduledoc """
  The lists behind a client's own tabs. Setting a bookmark worked before this;
  finding it again did not.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Social

  @mastodon_host "mastodon.localhost"

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
