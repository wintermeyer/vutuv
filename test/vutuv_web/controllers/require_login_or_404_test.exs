defmodule VutuvWeb.RequireLoginOr404Test do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Social.Follow

  # The follow and membership controllers deliberately 404 (NOT redirect
  # like the RequireLogin plug) when there is no session user. That guard is
  # copied verbatim into both, so it gets pulled into a shared
  # `RequireLoginOr404` plug. These tests pin the 404-not-redirect behavior at
  # the request boundary so the extraction stays byte-identical.

  describe "FollowController without a session user" do
    test "create 404s and creates nothing", %{conn: conn} do
      followee = insert(:user)

      conn =
        post(conn, ~p"/follows", follow: %{"followee_id" => followee.id})

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(Follow, :count) == 0
    end

    test "delete 404s", %{conn: conn} do
      conn = delete(conn, ~p"/follows/0")
      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "MembershipController without a session user" do
    test "create 404s", %{conn: conn} do
      conn = post(conn, ~p"/memberships", membership: %{})
      assert conn.status == 404
      assert conn.halted
    end

    test "delete 404s", %{conn: conn} do
      conn = delete(conn, ~p"/memberships/0")
      assert conn.status == 404
      assert conn.halted
    end
  end
end
