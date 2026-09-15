defmodule VutuvWeb.PostAnalyticsControllerTest do
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  test "the author sees the analysis through the post menu", %{conn: conn} do
    {conn, author} = create_and_login_user(conn)
    post = create_post!(author, %{body: "An interesting post"})

    assert get(conn, "/#{author.username}/posts/#{post.id}").resp_body =~
             "/posts/#{post.id}/analytics"

    analytics = get(conn, "/posts/#{post.id}/analytics")
    assert html_response(analytics, 200) =~ "Interactions over time"
    assert Plug.Conn.get_resp_header(analytics, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "another member cannot read the analysis", %{conn: conn} do
    author = insert_activated_user()
    post = create_post!(author, %{body: "Private statistics"})
    {conn, _other} = create_and_login_user(conn)

    assert get(conn, "/posts/#{post.id}/analytics").status == 404
  end

  test "signed-out readers are sent to login", %{conn: conn} do
    post = create_post!(insert_activated_user(), %{body: "Only the author can analyze this"})

    assert get(conn, "/posts/#{post.id}/analytics").status in [302, 303]
  end
end
