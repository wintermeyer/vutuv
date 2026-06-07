defmodule VutuvWeb.UserTagControllerTest do
  use VutuvWeb.ConnCase, async: true

  # `UserTagController.resolve_slug` is a plug that runs before every action.
  # When the slug does not resolve to a user tag it must render a clean 404 and
  # *halt*: without the halt the pipeline falls through into `show/2` / `delete/2`
  # with `conn.assigns[:user_tag] == nil`, which crashes (500 / double render)
  # instead of returning the 404. Every sibling resolver halts on the nil
  # branch, so this controller must too.

  describe "resolve_slug on an unknown user-tag slug" do
    setup %{conn: conn} do
      user = insert_validated_user()
      {:ok, conn: conn, user: user}
    end

    test "GET show returns a clean 404 instead of falling through", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/tags/does-not-exist")

      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "resolve_slug on an unknown user-tag slug for a logged-in user" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "DELETE returns a clean 404 instead of crashing", %{conn: conn, user: user} do
      conn = delete(conn, ~p"/#{user}/tags/does-not-exist")

      assert conn.status == 404
      assert conn.halted
    end
  end
end
