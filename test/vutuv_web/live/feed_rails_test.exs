defmodule VutuvWeb.PostLive.FeedRailsTest do
  use VutuvWeb.ConnCase, async: true

  # The feed's rail renders WITH the page: a lazily loaded rail popped in
  # noticeably
  # after the paint on desktop, which read as the page being slow (Stefan,
  # 2026-07-30 — the v7.200.3 laziness is deliberately undone). The rail is
  # computed once on the dead render and rides the mount handoff to the
  # connected socket, so a visit still pays for it only once; phones keep it
  # hidden under md (CSS), which is the accepted cost of shipping it eagerly.

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Tags

  defp seed_rails(user) do
    tag = insert(:tag)
    Tags.follow_tag(user, tag)

    # One newcomer for the welcome card — it only greets members who show a
    # face.
    newbie = insert(:activated_user, first_name: "New", last_name: "Face", avatar: "selfie.jpg")
    {:ok, post} = Posts.create_post(newbie, %{body: "hello from a new face"})

    %{tag: tag, newbie: newbie, post: post}
  end

  test "the dead render ships the rail cards", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag} = seed_rails(user)

    html = conn |> get(~p"/feed") |> html_response(200)

    assert html =~ ~s(id="feed-rail")
    assert html =~ ~s(id="followed-tag-#{tag.id})
    assert html =~ ~s(id="newcomers")
    refute html =~ "LazyRails"
  end

  test "the connected mount shows the rail without any client request", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag, newbie: newbie} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    assert has_element?(view, "#followed-tag-#{tag.id}")
    assert has_element?(view, ~s(#newcomers a[href="/#{newbie.username}"]))
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
    %{tag: tag, newbie: newbie} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # A tag followed in another tab and the periodic reshuffle tick both
    # redraw the rail on an open feed; the rail must survive them filled.
    send(view.pid, {:tag_follows_changed, %{}})
    send(view.pid, :refresh_suggestions)
    render(view)

    assert has_element?(view, "#followed-tag-#{tag.id}")
    assert has_element?(view, ~s(#newcomers a[href="/#{newbie.username}"]))
  end
end
