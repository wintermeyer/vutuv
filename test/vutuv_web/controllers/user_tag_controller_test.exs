defmodule VutuvWeb.UserTagControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Tags.UserTag

  defp tag_count(user),
    do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count)

  describe "create (the one place tags are added — single or comma-separated)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "adds a single tag and redirects to the tags page", %{conn: conn, user: user} do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      assert tag_count(user) == 1
    end

    test "adds several comma-separated tags at once", %{conn: conn, user: user} do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir, Phoenix , Ruby on Rails"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      # The blank-padded middle entry is trimmed, not dropped.
      assert tag_count(user) == 3
    end

    test "ignores empty segments between commas", %{conn: conn, user: user} do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir, , Ruby,"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      assert tag_count(user) == 2
    end

    test "re-renders the form with an error when nothing usable is typed", %{conn: conn, user: user} do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: ""})

      assert html_response(conn, 200) =~ "editform"
      assert tag_count(user) == 0
    end
  end

  # `UserTagController.resolve_slug` is a plug that runs before every action.
  # When the slug does not resolve to a user tag it must render a clean 404 and
  # *halt*: without the halt the pipeline falls through into `show/2` / `delete/2`
  # with `conn.assigns[:user_tag] == nil`, which crashes (500 / double render)
  # instead of returning the 404. Every sibling resolver halts on the nil
  # branch, so this controller must too.

  describe "resolve_slug on an unknown user-tag slug" do
    setup %{conn: conn} do
      user = insert_activated_user()
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
