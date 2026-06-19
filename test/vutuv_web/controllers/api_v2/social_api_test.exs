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

    test "connections list shows accepted connections only", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      connect!(me, other)
      pending = insert_activated_user()
      {:ok, _} = Social.request_connection(pending, me)

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

  describe "connection lifecycle" do
    test "request, accept, list, disconnect", %{
      conn: conn,
      me: me,
      other: other,
      token: token,
      other_token: other_token
    } do
      conn1 = post(authed(conn, token), "/api/2.0/users/#{other.username}/connection")

      assert %{"id" => id, "status" => "pending", "requested_by_me" => true} =
               json_response(conn1, 201)

      conn2 = post(authed(build_conn(), other_token), "/api/2.0/connections/#{id}/accept")
      assert %{"status" => "accepted", "requested_by_me" => false} = json_response(conn2, 200)

      # Acceptance materialized the mutual follow, like on the website.
      assert Social.user_follows_user?(me.id, other.id)
      assert Social.user_follows_user?(other.id, me.id)

      conn3 = get(authed(build_conn(), token), "/api/2.0/users/#{me.username}/relationship")
      assert json_response(conn3, 200)["self"] == true

      conn4 = get(authed(build_conn(), token), "/api/2.0/users/#{other.username}/relationship")

      assert %{"connection" => %{"status" => "accepted"}, "following" => true} =
               json_response(conn4, 200)

      conn5 = delete(authed(build_conn(), token), "/api/2.0/connections/#{id}")
      assert conn5.status == 204
    end

    test "a mutual request auto-accepts", %{conn: conn, me: me, other: other, token: token} do
      {:ok, _} = Social.request_connection(other, me)

      conn = post(authed(conn, token), "/api/2.0/users/#{other.username}/connection")
      assert json_response(conn, 200)["status"] == "accepted"
    end

    test "double request is a 409 with the reason", %{conn: conn, other: other, token: token} do
      post(authed(conn, token), "/api/2.0/users/#{other.username}/connection")

      conn = post(authed(build_conn(), token), "/api/2.0/users/#{other.username}/connection")
      assert conn.status == 409
      assert api_problem(conn)["reason"] == "already_requested"
    end

    test "only the recipient can accept", %{conn: conn, other: other, token: token} do
      conn1 = post(authed(conn, token), "/api/2.0/users/#{other.username}/connection")
      %{"id" => id} = json_response(conn1, 201)

      # The requester accepting their own request is a 404, like on the web.
      conn2 = post(authed(build_conn(), token), "/api/2.0/connections/#{id}/accept")
      assert conn2.status == 404
    end

    test "decline answers with the declined state", %{
      conn: conn,
      other: other,
      token: token,
      other_token: other_token
    } do
      conn1 = post(authed(conn, token), "/api/2.0/users/#{other.username}/connection")
      %{"id" => id} = json_response(conn1, 201)

      conn2 = post(authed(build_conn(), other_token), "/api/2.0/connections/#{id}/decline")
      assert json_response(conn2, 200)["status"] == "declined"
    end
  end
end
