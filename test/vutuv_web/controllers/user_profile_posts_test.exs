defmodule VutuvWeb.UserProfilePostsTest do
  @moduledoc """
  The profile page's Posts section: latest visible posts as previews,
  visibility-filtered per viewer, absent when there is nothing to show.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  test "shows the latest posts as previews", %{conn: conn} do
    user = insert_activated_user()
    {:ok, _} = Posts.create_post(user, %{body: "profile post"})

    conn = get(conn, "/#{user.username}")

    assert html_response(conn, 200) =~ "profile-posts"
    assert conn.resp_body =~ "profile post"
  end

  test "a logged-out visitor sees the post action bar without crashing", %{conn: conn} do
    user = insert_activated_user()
    {:ok, post} = Posts.create_post(user, %{body: "public post"})

    conn = get(conn, "/#{user.username}")

    assert html_response(conn, 200) =~ "public post"
    # The action bar renders for an anonymous viewer: viewer_id resolves to nil
    # (not the `false` an `&&` would yield, which Posts.post_engagement/2 has no
    # clause for and would crash on).
    assert conn.resp_body =~ ~s(id="post-actions-post-#{post.id}-like")
  end

  test "post timestamps render server-side in Berlin time, not client-localized", %{conn: conn} do
    user = insert_activated_user()
    {:ok, post} = Posts.create_post(user, %{body: "timed post"})

    conn = get(conn, "/#{user.username}")
    body = html_response(conn, 200)

    # Post times are rendered on the server in Europe/Berlin time
    # (Vutuv.BerlinTime, via VutuvWeb.UI.post_time/1), so a post from today
    # shows just the time. The <time> keeps a UTC-marked datetime ("Z") for
    # machines but carries NO data-localtime marker: app.js must leave it alone.
    assert body =~ ~s(datetime="#{NaiveDateTime.to_iso8601(post.inserted_at)}Z")
    refute body =~ ~s(data-localtime)
  end

  test "the owner sees the card with an Add link even when empty", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = get(conn, "/#{user.username}")

    assert html_response(conn, 200) =~ "profile-posts"
    assert conn.resp_body =~ ~s(href="/feed")
    # The empty card invites the owner to write rather than dead-ending.
    assert conn.resp_body =~ "Write your first post"
  end

  test "the owner gets the ⋯ menu on each post, visitors do not", %{conn: conn} do
    {owner_conn, user} = create_and_login_user(conn)
    {:ok, post} = Vutuv.Posts.create_post(user, %{body: "my post"})

    owner_view = get(owner_conn, "/#{user.username}")
    assert html_response(owner_view, 200) =~ ~s(id="post-menu-post-#{post.id}")
    assert owner_view.resp_body =~ ~s(href="/posts/#{post.id}/edit")
    assert owner_view.resp_body =~ ~s(data-method="delete")

    # The original conn never logged in: a plain visitor.
    visitor_view = get(conn, "/#{user.username}")
    refute html_response(visitor_view, 200) =~ "post-menu-post-#{post.id}"
  end

  test "filters restricted posts per viewer and omits the empty section", %{conn: conn} do
    user = insert_activated_user()

    {:ok, _} =
      Posts.create_post(user, %{body: "members club", denials: [%{"wildcard" => "logged_out"}]})

    # Anonymous: the only post is hidden, so no section at all.
    anonymous = get(conn, "/#{user.username}")
    refute anonymous.resp_body =~ "profile-posts"
    refute anonymous.resp_body =~ "members club"

    # A logged-in member sees it.
    {member_conn, _member} = create_and_login_user(conn)
    member_view = get(member_conn, "/#{user.username}")
    assert member_view.resp_body =~ "members club"
  end
end
