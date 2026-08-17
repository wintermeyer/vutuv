defmodule VutuvWeb.MastodonApi.NotificationControllerTest do
  @moduledoc """
  The notifications tab, which answered an empty list until now although vutuv
  has had real notifications all along.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Activity
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

  test "a like and a follow arrive as favourite and follow", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Worauf reagiert wird"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = token_for(member, ["read"])
    notifications = conn |> api(token) |> get("/api/v1/notifications") |> json_response(200)

    types = notifications |> Enum.map(& &1["type"]) |> Enum.sort()
    assert types == ["favourite", "follow"]

    favourite = Enum.find(notifications, &(&1["type"] == "favourite"))
    assert favourite["account"]["id"] == liker.id
    assert favourite["status"]["id"] == post.id

    follow = Enum.find(notifications, &(&1["type"] == "follow"))
    assert follow["account"]["id"] == follower.id
    assert follow["status"] == nil
  end

  # vutuv has kinds Mastodon does not — a tag endorsement is the everyday one.
  # Serving it under an invented type is worse than leaving it out, because a
  # client can neither render nor act on a type it does not know.
  test "a kind Mastodon has no type for is left out rather than invented", %{conn: conn} do
    member = insert(:activated_user)
    endorser = insert(:activated_user)
    user_tag = insert(:user_tag, user: member)

    Activity.notify_endorsement(member.id, endorser, Vutuv.Repo.preload(user_tag, :tag).tag)

    token = token_for(member, ["read"])
    notifications = conn |> api(token) |> get("/api/v1/notifications") |> json_response(200)

    assert notifications == []
  end

  test "types[] and exclude_types[] narrow the list", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Beides"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = token_for(member, ["read"])

    only_follows =
      conn
      |> api(token)
      |> get("/api/v1/notifications?types[]=follow")
      |> json_response(200)

    assert Enum.map(only_follows, & &1["type"]) == ["follow"]

    without_follows =
      build_conn()
      |> api(token)
      |> get("/api/v1/notifications?exclude_types[]=follow")
      |> json_response(200)

    assert Enum.map(without_follows, & &1["type"]) == ["favourite"]
  end

  test "the unread count and clearing it", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = token_for(member, ["read", "write"])

    assert %{"count" => count} =
             conn
             |> api(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)

    assert count >= 1

    assert build_conn()
           |> api(token)
           |> post("/api/v1/notifications/clear")
           |> json_response(200) == %{}

    assert %{"count" => 0} =
             build_conn()
             |> api(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)
  end

  test "a single notification can be fetched and an unknown id is a 404", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = token_for(member, ["read"])
    [one] = conn |> api(token) |> get("/api/v1/notifications") |> json_response(200)

    fetched =
      build_conn()
      |> api(token)
      |> get("/api/v1/notifications/#{one["id"]}")
      |> json_response(200)

    assert fetched["id"] == one["id"]

    assert build_conn()
           |> api(token)
           |> get("/api/v1/notifications/follower-#{Ecto.UUID.generate()}")
           |> response(404)
  end
end
