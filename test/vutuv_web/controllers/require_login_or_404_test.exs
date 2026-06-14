defmodule VutuvWeb.RequireLoginOr404Test do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Social.Follow

  # The FollowController deliberately 404s (NOT redirect like the RequireLogin
  # plug) when there is no session user, via the shared `RequireLoginOr404`
  # plug. This test pins the 404-not-redirect behavior at the request boundary.

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
end
