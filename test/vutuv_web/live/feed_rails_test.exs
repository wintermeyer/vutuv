defmodule VutuvWeb.PostLive.FeedRailsTest do
  use VutuvWeb.ConnCase, async: true

  # The feed's discovery rail (Tags you follow / Who to follow / Suggested
  # posts) renders WITH the page again: a lazily loaded rail popped in
  # noticeably after the paint on desktop, which read as the page being slow
  # (Stefan, 2026-07-30 — the v7.200.3 laziness is deliberately undone).
  # The rail is computed once on the dead render and rides the mount handoff
  # to the connected socket, so a visit still pays for it only once; phones
  # keep it hidden under md (CSS), which is the accepted cost of shipping it
  # eagerly.

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Tags

  defp seed_rails(user) do
    tag = insert(:tag)
    Tags.follow_tag(user, tag)

    popular = insert(:activated_user, first_name: "Pop", last_name: "Ular")
    insert(:follow, follower: insert(:activated_user), followee: popular)
    {:ok, post} = Posts.create_post(popular, %{body: "something worth discovering"})

    %{tag: tag, popular: popular, post: post}
  end

  test "the dead render ships all three rail cards", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag} = seed_rails(user)

    html = conn |> get(~p"/feed") |> html_response(200)

    assert html =~ ~s(id="feed-rail")
    assert html =~ ~s(id="followed-tag-#{tag.id})
    assert html =~ ~s(id="who-to-follow")
    assert html =~ ~s(id="discover-posts")
    refute html =~ "LazyRails"
  end

  test "the connected mount shows the rail without any client request", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag, popular: popular, post: post} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    assert has_element?(view, "#followed-tag-#{tag.id}")
    assert has_element?(view, ~s(#who-to-follow a[href="/#{popular.username}"]))

    assert has_element?(
             view,
             ~s(#discover-posts a[href="/#{popular.username}/posts/#{post.id}"])
           )
  end

  test "the rail is live: unfollowing a tag drops its chip", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    view
    |> element(~s(#followed-tag-#{tag.id} button[phx-click="unfollow_tag"]))
    |> render_click()

    refute has_element?(view, "#followed-tag-#{tag.id}")
    refute Tags.tag_followed?(user, tag)
  end

  test "rail refresh signals redraw an already-filled rail", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag, popular: popular} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # A tag followed in another tab and the periodic reshuffle tick both
    # redraw the rail on an open feed; the rail must survive them filled.
    send(view.pid, {:tag_follows_changed, %{}})
    send(view.pid, :refresh_suggestions)
    render(view)

    assert has_element?(view, "#followed-tag-#{tag.id}")
    assert has_element?(view, ~s(#who-to-follow a[href="/#{popular.username}"]))
  end
end
