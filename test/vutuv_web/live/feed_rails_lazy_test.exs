defmodule VutuvWeb.PostLive.FeedRailsLazyTest do
  use VutuvWeb.ConnCase, async: true

  # The feed's discovery rail (Tags you follow / Who to follow / Suggested
  # posts) is desktop-only (hidden under md) yet used to cost the majority of
  # the feed's queries on every mount — twice per visit, phones included. It
  # is now lazy: neither the dead render nor the connected mount computes it;
  # the LazyRails hook reports a rail-showing viewport with "load-rails" and
  # only that event fills the aside. Phones never send it.

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

  test "the dead render ships the aside empty, with the hook anchor", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    seed_rails(user)

    html = conn |> get(~p"/feed") |> html_response(200)

    assert html =~ ~s(id="feed-rail")
    assert html =~ ~s(phx-hook="LazyRails")
    assert html =~ ~s(id="feed-other-formats")
    refute html =~ ~s(id="followed-tags")
    refute html =~ ~s(id="who-to-follow")
    refute html =~ ~s(id="discover-posts")
  end

  test "the connected mount alone still leaves the rail empty", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    refute has_element?(view, "#followed-tags")
    refute has_element?(view, "#who-to-follow")
    refute has_element?(view, "#discover-posts")
  end

  test "load-rails fills all three rail cards", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag, popular: popular, post: post} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    view |> element("#feed-rail") |> render_hook("load-rails")

    assert has_element?(view, "#followed-tag-#{tag.id}")
    assert has_element?(view, ~s(#who-to-follow a[href="/#{popular.username}"]))

    assert has_element?(
             view,
             ~s(#discover-posts a[href="/#{popular.username}/posts/#{post.id}"])
           )
  end

  test "a second load-rails is a no-op, not a recompute", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{popular: popular} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    view |> element("#feed-rail") |> render_hook("load-rails")
    view |> element("#feed-rail") |> render_hook("load-rails")

    assert has_element?(view, ~s(#who-to-follow a[href="/#{popular.username}"]))
  end

  test "the loaded rail stays live: unfollowing a tag drops its chip", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{tag: tag} = seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    view |> element("#feed-rail") |> render_hook("load-rails")

    view
    |> element(~s(#followed-tag-#{tag.id} button[phx-click="unfollow_tag"]))
    |> render_click()

    refute has_element?(view, "#followed-tag-#{tag.id}")
    refute Tags.tag_followed?(user, tag)
  end

  test "rail refresh signals before load-rails leave the rail empty", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    seed_rails(user)

    {:ok, view, _html} = live(conn, ~p"/feed")

    # A tag followed in another tab and the periodic reshuffle tick both
    # redraw the rail on an open feed — but only once the viewport asked for
    # it. A phone's feed must not be made to pay the rail queries sideways.
    send(view.pid, {:tag_follows_changed, %{}})
    send(view.pid, :refresh_suggestions)
    render(view)

    refute has_element?(view, "#followed-tags")
    refute has_element?(view, "#who-to-follow")
    refute has_element?(view, "#discover-posts")
  end
end
