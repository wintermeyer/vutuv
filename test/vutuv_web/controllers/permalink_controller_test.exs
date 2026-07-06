defmodule VutuvWeb.PermalinkControllerTest do
  @moduledoc """
  The username-independent profile permalink (issue #904):
  `/system/permalinks/users/:user_id` 302-redirects to the member's current
  `/:username`, so a link built from the never-changing UUID v7 id survives
  every rename.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts

  describe "GET /system/permalinks/users/:user_id" do
    test "redirects to the member's current profile", %{conn: conn} do
      user = insert_activated_user(first_name: "Anna", last_name: "Adler")

      conn = get(conn, ~p"/system/permalinks/users/#{user.id}")

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "the same permalink keeps working after the username changes", %{conn: conn} do
      user = insert_activated_user()
      permalink = ~p"/system/permalinks/users/#{user.id}"

      {:ok, renamed} = Accounts.update_username(user, %{"username" => "renamed_member"})

      conn = get(conn, permalink)

      # It now points at the new handle, not the freed old one.
      assert redirected_to(conn) == ~p"/#{renamed}"
      assert redirected_to(conn) == "/renamed_member"
    end

    test "404s for an unknown id rather than 500ing", %{conn: conn} do
      conn = get(conn, ~p"/system/permalinks/users/#{Vutuv.UUIDv7.generate()}")

      assert conn.status == 404
    end

    test "404s for a malformed (non-UUID) id rather than raising a CastError", %{conn: conn} do
      conn = get(conn, "/system/permalinks/users/not-a-uuid")

      assert conn.status == 404
    end
  end
end
