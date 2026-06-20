defmodule VutuvWeb.ApiV2.SocialApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Social

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    me = insert_activated_user()
    other = insert_activated_user()

    {:ok, token, _} =
      ApiAuth.create_pat(me, %{"name" => "t", "scopes" => ["social:write"]})

    {:ok, other_token, _} =
      ApiAuth.create_pat(other, %{"name" => "t", "scopes" => ["social:write"]})

    {:ok, conn: conn, me: me, other: other, token: token, other_token: other_token}
  end

  describe "people lists" do
    test "followers and following with totals", %{conn: conn, me: me, other: other, token: token} do
      follow!(other, me)
      follow!(me, other)

      conn1 = get(authed(conn, token), "/api/2.0/users/#{me.username}/followers")
      assert %{"total" => 1, "people" => [%{"username" => slug}]} = json_response(conn1, 200)
      assert slug == other.username

      conn2 = get(authed(build_conn(), token), "/api/2.0/users/#{me.username}/following")
      assert %{"total" => 1} = json_response(conn2, 200)
    end

    test "connections list shows the member's mutual follows only", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      connect!(me, other)
      # A one-way follow is not a connection and must not appear.
      one_way = insert_activated_user()
      follow!(me, one_way)

      conn = get(authed(conn, token), "/api/2.0/users/#{me.username}/connections")
      assert %{"total" => 1, "people" => [%{"username" => slug}]} = json_response(conn, 200)
      assert slug == other.username
    end

    test "social scope is required", %{conn: conn, me: me, other: other} do
      {:ok, profile_only, _} =
        ApiAuth.create_pat(me, %{"name" => "p", "scopes" => ["profile:read"]})

      conn = get(authed(conn, profile_only), "/api/2.0/users/#{other.username}/followers")
      assert conn.status == 403
    end
  end

  describe "PUT/DELETE /users/:slug/follow" do
    test "follow, idempotent re-follow, unfollow", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      conn1 = put(authed(conn, token), "/api/2.0/users/#{other.username}/follow")
      assert %{"following" => true} = json_response(conn1, 201)
      assert Social.user_follows_user?(me.id, other.id)

      conn2 = put(authed(build_conn(), token), "/api/2.0/users/#{other.username}/follow")
      assert json_response(conn2, 200)["following"] == true

      conn3 = delete(authed(build_conn(), token), "/api/2.0/users/#{other.username}/follow")
      assert conn3.status == 204
      refute Social.user_follows_user?(me.id, other.id)

      conn4 = delete(authed(build_conn(), token), "/api/2.0/users/#{other.username}/follow")
      assert conn4.status == 404
    end

    test "cannot follow yourself", %{conn: conn, me: me, token: token} do
      conn = put(authed(conn, token), "/api/2.0/users/#{me.username}/follow")
      assert conn.status == 422
    end

    test "a block refuses the follow", %{conn: conn, me: me, other: other, token: token} do
      {:ok, _} = Social.block_user(other, me)

      conn = put(authed(conn, token), "/api/2.0/users/#{other.username}/follow")
      assert conn.status == 403
    end
  end

  describe "relationship + vernetzt (mutual follow)" do
    test "relationship reports following / followed_by / connected", %{
      conn: conn,
      me: me,
      other: other,
      token: token,
      other_token: other_token
    } do
      # Self.
      conn1 = get(authed(conn, token), "/api/2.0/users/#{me.username}/relationship")
      assert json_response(conn1, 200)["self"] == true

      # I follow them one-way: not connected yet.
      put(authed(build_conn(), token), "/api/2.0/users/#{other.username}/follow")
      conn2 = get(authed(build_conn(), token), "/api/2.0/users/#{other.username}/relationship")

      assert %{"following" => true, "followed_by" => false, "connected" => false} =
               json_response(conn2, 200)

      # They follow back → vernetzt.
      put(authed(build_conn(), other_token), "/api/2.0/users/#{me.username}/follow")
      conn3 = get(authed(build_conn(), token), "/api/2.0/users/#{other.username}/relationship")

      assert %{"following" => true, "followed_by" => true, "connected" => true} =
               json_response(conn3, 200)
    end

    test "a follow-back reports connected on the follow doc", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      # They already follow me; I follow back → the follow response is connected.
      follow!(other, me)

      conn = put(authed(conn, token), "/api/2.0/users/#{other.username}/follow")
      assert %{"following" => true, "connected" => true} = json_response(conn, 201)
    end
  end
end
