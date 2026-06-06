defmodule VutuvWeb.UserProfilePostsTest do
  @moduledoc """
  The profile page's Posts section: latest visible posts as previews,
  visibility-filtered per viewer, absent when there is nothing to show.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  defp author(attrs \\ []) do
    user = insert(:user, Keyword.merge([validated?: true], attrs))
    insert(:slug, user: user, value: user.active_slug, disabled: false)
    user
  end

  test "shows the latest posts as previews", %{conn: conn} do
    user = author()
    {:ok, _} = Posts.create_post(user, %{body: "profile post"})

    conn = get(conn, "/#{user.active_slug}")

    assert html_response(conn, 200) =~ "profile-posts"
    assert conn.resp_body =~ "profile post"
  end

  test "the owner sees the card with an Add link even when empty", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = get(conn, "/#{user.active_slug}")

    assert html_response(conn, 200) =~ "profile-posts"
    assert conn.resp_body =~ ~s(href="/feed")
    assert conn.resp_body =~ "Nothing here yet."
  end

  test "the owner gets the ⋯ menu on each post, visitors do not", %{conn: conn} do
    {owner_conn, user} = create_and_login_user(conn)
    {:ok, post} = Vutuv.Posts.create_post(user, %{body: "my post"})

    owner_view = get(owner_conn, "/#{user.active_slug}")
    assert html_response(owner_view, 200) =~ ~s(id="post-menu-post-#{post.id}")
    assert owner_view.resp_body =~ ~s(href="/posts/#{post.id}/edit")
    assert owner_view.resp_body =~ ~s(data-method="delete")

    # The original conn never logged in: a plain visitor.
    visitor_view = get(conn, "/#{user.active_slug}")
    refute html_response(visitor_view, 200) =~ "post-menu-post-#{post.id}"
  end

  test "filters restricted posts per viewer and omits the empty section", %{conn: conn} do
    user = author()

    {:ok, _} =
      Posts.create_post(user, %{body: "members club", denials: [%{"wildcard" => "logged_out"}]})

    # Anonymous: the only post is hidden, so no section at all.
    anonymous = get(conn, "/#{user.active_slug}")
    refute anonymous.resp_body =~ "profile-posts"
    refute anonymous.resp_body =~ "members club"

    # A logged-in member sees it.
    {member_conn, _member} = create_and_login_user(conn)
    member_view = get(member_conn, "/#{user.active_slug}")
    assert member_view.resp_body =~ "members club"
  end
end
