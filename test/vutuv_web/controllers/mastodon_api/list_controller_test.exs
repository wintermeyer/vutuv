defmodule VutuvWeb.MastodonApi.ListControllerTest do
  @moduledoc """
  The lists behind a client's own tabs. Setting a bookmark worked before this;
  finding it again did not.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.ApiAuth
  alias Vutuv.Posts
  alias Vutuv.Social

  @mastodon_host "mastodon.localhost"

  defp token_for(user, scopes) do
    plaintext = "vutuv_at_" <> ApiAuth.random_token()
    app = insert(:oauth_app, user: nil, protocol: "mastodon", registered_scopes: scopes)

    insert(:api_token,
      user: user,
      app: app,
      kind: "access",
      name: nil,
      scopes: scopes,
      expires_at: nil,
      token_hash: ApiAuth.hash_token(plaintext)
    )

    plaintext
  end

  defp api(conn, token) do
    conn
    |> Map.put(:host, @mastodon_host)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "what you bookmarked and what you liked come back", %{conn: conn} do
    member = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, saved} = Posts.create_post(author, %{body: "Zum Merken"})
    {:ok, liked} = Posts.create_post(author, %{body: "Gefällt mir"})

    :ok = Posts.bookmark_post(member, saved)
    :ok = Posts.like_post(member, liked)

    token = token_for(member, ["read"])

    bookmarks = conn |> api(token) |> get("/api/v1/bookmarks") |> json_response(200)
    assert Enum.map(bookmarks, & &1["id"]) == [saved.id]

    favourites = build_conn() |> api(token) |> get("/api/v1/favourites") |> json_response(200)
    assert Enum.map(favourites, & &1["id"]) == [liked.id]
  end

  test "the follower list", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = token_for(member, ["read"])

    accounts =
      conn |> api(token) |> get("/api/v1/accounts/#{member.id}/followers") |> json_response(200)

    assert Enum.map(accounts, & &1["id"]) == [follower.id]
  end

  test "blocked and muted members are listed", %{conn: conn} do
    member = insert(:activated_user)
    blocked = insert(:activated_user)
    muted = insert(:activated_user)

    {:ok, _} = Social.block_user(member, blocked)
    {:ok, _} = Social.follow(member, muted.id)
    Social.set_follow_mute(member, muted, true)

    token = token_for(member, ["read"])

    blocks = conn |> api(token) |> get("/api/v1/blocks") |> json_response(200)
    assert Enum.map(blocks, & &1["id"]) == [blocked.id]

    mutes = build_conn() |> api(token) |> get("/api/v1/mutes") |> json_response(200)
    assert Enum.map(mutes, & &1["id"]) == [muted.id]
  end

  test "who liked and who reposted a status", %{conn: conn} do
    author = insert(:activated_user)
    liker = insert(:activated_user)
    reposter = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Reaktionen"})
    :ok = Posts.like_post(liker, post)
    :ok = Posts.repost_post(reposter, post)

    token = token_for(insert(:activated_user), ["read"])

    liked_by =
      conn
      |> api(token)
      |> get("/api/v1/statuses/#{post.id}/favourited_by")
      |> json_response(200)

    assert Enum.map(liked_by, & &1["id"]) == [liker.id]

    reblogged_by =
      build_conn()
      |> api(token)
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

    token = token_for(stranger, ["read"])

    assert conn
           |> api(token)
           |> get("/api/v1/statuses/#{private.id}/favourited_by")
           |> response(404)
  end

  test "the public timeline lists site-feed posts", %{conn: conn} do
    author = insert(:activated_user, noindex?: false, noai?: false)
    {:ok, post} = Posts.create_post(author, %{body: "Für die Allgemeinheit"})

    token = token_for(insert(:activated_user), ["read"])

    statuses =
      conn |> api(token) |> get("/api/v1/timelines/public") |> json_response(200)

    assert Enum.any?(statuses, &(&1["id"] == post.id))
  end

  # The site feed lists only members who opted out of nothing, and the public
  # timeline inherits that rather than inventing a wider firehose.
  test "a member who opted out of aggregation stays out of the public timeline", %{conn: conn} do
    author = insert(:activated_user, noindex?: true)
    {:ok, post} = Posts.create_post(author, %{body: "Nicht im Aggregat"})

    token = token_for(insert(:activated_user), ["read"])

    statuses =
      conn |> api(token) |> get("/api/v1/timelines/public") |> json_response(200)

    refute Enum.any?(statuses, &(&1["id"] == post.id))
  end

  test "a hashtag timeline answers its posts, an unknown tag an empty list", %{conn: conn} do
    author = insert(:activated_user)
    tag = insert(:tag)
    {:ok, post} = Posts.create_post(author, %{body: "Zum Thema ##{tag.slug}"})

    token = token_for(insert(:activated_user), ["read"])

    statuses =
      conn
      |> api(token)
      |> get("/api/v1/timelines/tag/#{tag.slug}")
      |> json_response(200)

    assert Enum.any?(statuses, &(&1["id"] == post.id))

    assert build_conn()
           |> api(token)
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
