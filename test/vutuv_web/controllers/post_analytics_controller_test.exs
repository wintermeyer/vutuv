defmodule VutuvWeb.PostAnalyticsControllerTest do
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  test "the author sees the reach analysis through the post menu", %{conn: conn} do
    {conn, author} = create_and_login_user(conn)
    post = create_post!(author, %{body: "An interesting post"})

    assert get(conn, "/#{author.username}/posts/#{post.id}").resp_body =~
             "Reach analysis (Beta)"

    analytics = get(conn, "/posts/#{post.id}/analytics")
    body = html_response(analytics, 200)
    assert body =~ "Reach analysis"
    assert body =~ "Known readers"
    assert body =~ "Server network"
    assert body =~ "Momentum over time"
    assert body =~ "do not represent repost paths"
    refute body =~ "Distribution signal"
    refute body =~ "This post broke out"
    refute body =~ "No visible response yet"
    assert body =~ "The real readership is almost certainly much higher"
    assert body =~ ~r/<strong[^>]*>lower bound<\/strong>/
    assert body =~ "people on other social platforms"

    assert body =~ ~s(/posts/#{post.id}/analytics/og.png)
  end

  test "a public post's analysis is public without a login", %{conn: conn} do
    author = insert_activated_user()
    post = create_post!(author, %{body: "Public statistics"})

    analytics = get(conn, "/posts/#{post.id}/analytics")

    assert html_response(analytics, 200) =~ "Reach analysis"
    assert get_resp_header(analytics, "cache-control") == ["public, max-age=60"]
  end

  test "another member sees the reach analysis in a public post's menu", %{conn: conn} do
    author = insert_activated_user()
    post = create_post!(author, %{body: "Public menu"})
    {conn, _reader} = create_and_login_user(conn)

    assert get(conn, "/#{author.username}/posts/#{post.id}").resp_body =~
             "Reach analysis (Beta)"
  end

  test "another member cannot read a restricted post's analysis", %{conn: conn} do
    author = insert_activated_user()

    post =
      create_post!(author, %{
        body: "Private statistics",
        denials: [%{wildcard: "logged_out"}]
      })

    {conn, _other} = create_and_login_user(conn)

    assert get(conn, "/posts/#{post.id}/analytics").status == 404
  end

  test "the author retains private access to a restricted post's analysis", %{conn: conn} do
    {conn, author} = create_and_login_user(conn)

    post =
      create_post!(author, %{
        body: "Private statistics",
        denials: [%{wildcard: "logged_out"}]
      })

    analytics = get(conn, "/posts/#{post.id}/analytics")

    assert html_response(analytics, 200) =~ "Reach analysis"
    assert get_resp_header(analytics, "cache-control") == ["private, no-store"]
    assert get_resp_header(analytics, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "a restricted analysis stays hidden from signed-out readers", %{conn: conn} do
    post =
      create_post!(insert_activated_user(), %{
        body: "Only the author can analyze this",
        denials: [%{wildcard: "logged_out"}]
      })

    assert get(conn, "/posts/#{post.id}/analytics").status == 404
  end
end
