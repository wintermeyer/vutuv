defmodule VutuvWeb.MastodonApi.NotificationControllerTest do
  @moduledoc """
  The notifications tab, which answered an empty list until now although vutuv
  has had real notifications all along.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Social

  test "a like and a follow arrive as favourite and follow", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Worauf reagiert wird"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])

    notifications =
      conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

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

    token = mastodon_token(member, ["read"])

    notifications =
      conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

    assert notifications == []
  end

  test "types[] and exclude_types[] narrow the list", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Beides"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])

    only_follows =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?types[]=follow")
      |> json_response(200)

    assert Enum.map(only_follows, & &1["type"]) == ["follow"]

    without_follows =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?exclude_types[]=follow")
      |> json_response(200)

    assert Enum.map(without_follows, & &1["type"]) == ["favourite"]
  end

  test "the unread count and clearing it", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read", "write"])

    assert %{"count" => count} =
             conn
             |> mastodon_conn(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)

    assert count >= 1

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/notifications/clear")
           |> json_response(200) == %{}

    assert %{"count" => 0} =
             build_conn()
             |> mastodon_conn(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)
  end

  test "a single notification can be fetched and an unknown id is a 404", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])
    [one] = conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

    fetched =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/notifications/#{one["id"]}")
      |> json_response(200)

    assert fetched["id"] == one["id"]

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/notifications/follower-#{Ecto.UUID.generate()}")
           |> response(404)
  end
end
