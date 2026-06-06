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
