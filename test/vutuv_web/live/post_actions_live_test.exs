defmodule VutuvWeb.PostActionsLiveTest do
  @moduledoc """
  The per-card action bar (`VutuvWeb.PostLive.Actions`, embedded via
  `live_render` from the post card): like/bookmark/repost toggles, the live
  counter updates over the post topic, the repost lock on restricted posts —
  plus the /likes and /bookmarks pages fed by it.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([activated?: true], attrs))

  defp feed_actions(conn, post) do
    {:ok, feed, _html} = live(conn, ~p"/feed")
    %{view: find_live_child(feed, "post-actions-post-#{post.id}"), feed: feed}
  end

  describe "the action bar on the feed" do
    test "like toggles and counts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "likeable"})
      %{view: actions} = feed_actions(conn, post)

      html =
        actions
        |> element("#post-actions-post-#{post.id}-like")
        |> render_click()

      assert html =~ ~s(data-count="like")
      assert html =~ ~r/data-count="like">\s*1\s*</
      assert %{likes: 1} = Posts.engagement_counts(post.id)

      # Clicking again unlikes.
      html =
        actions
        |> element("#post-actions-post-#{post.id}-like")
        |> render_click()

      refute html =~ ~s(data-count="like")
      assert %{likes: 0} = Posts.engagement_counts(post.id)
    end

    test "bookmark toggles", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "keep"})
      %{view: actions} = feed_actions(conn, post)

      html =
        actions
        |> element("#post-actions-post-#{post.id}-bookmark")
        |> render_click()

      assert html =~ ~s(data-count="bookmark")
      assert %{bookmarks: 1} = Posts.engagement_counts(post.id)
    end

    test "repost toggles and locks the post's audience", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      post = create_post!(friend, %{body: "spread"})
      %{view: actions} = feed_actions(conn, post)

      html =
        actions
        |> element("#post-actions-post-#{post.id}-repost")
        |> render_click()

      assert html =~ ~s(data-count="repost")
      assert Posts.has_reposts?(post)

      assert {:error, :visibility_locked} =
               Posts.update_post(post, %{body: "spread", denials: [%{"wildcard" => "everyone"}]})
    end

    test "the reply button links to the reply page and counts live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "discussable"})
      %{view: actions} = feed_actions(conn, post)

      reply_button = "#post-actions-post-#{post.id}-reply"

      html = actions |> element(reply_button) |> render()
      assert html =~ ~s(href="/posts/#{post.id}/reply")
      refute html =~ ~s(data-count="reply")

      # Render once so the child is fully joined before the broadcast.
      assert render(actions) =~ "post-actions-post-#{post.id}-reply"

      {:ok, _} = Posts.create_reply(other_user(), post, %{body: "an answer"})

      html = actions |> element(reply_button) |> render()
      assert html =~ ~r/data-count="reply">\s*1\s*</
    end

    test "the reply button is disabled on restricted posts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "private", denials: [%{"wildcard" => "everyone"}]})
      %{view: actions} = feed_actions(conn, post)

      assert actions
             |> element("#post-actions-post-#{post.id}-reply")
             |> render() =~ "disabled"
    end

    test "the repost button is disabled on restricted posts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "private", denials: [%{"wildcard" => "everyone"}]})
      %{view: actions} = feed_actions(conn, post)

      assert actions
             |> element("#post-actions-post-#{post.id}-repost")
             |> render() =~ "disabled"
    end

    # components.css colors bare `a, button` elements brand-600, so each
    # button must carry its own state color: muted slate when inactive, the
    # active accent once toggled. Relying on inherited text color leaves
    # active and inactive reposts visually identical (both brand blue).
    test "buttons carry an explicit state color", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "state colors"})
      %{view: actions} = feed_actions(conn, post)

      like = "#post-actions-post-#{post.id}-like"
      assert actions |> element(like) |> render() =~ "text-slate-500"

      actions |> element(like) |> render_click()
      html = actions |> element(like) |> render()
      assert html =~ "text-accent"
      refute html =~ "text-slate-500"

      # The untouched buttons keep the muted state color.
      assert actions |> element("#post-actions-post-#{post.id}-repost") |> render() =~
               "text-slate-500"
    end

    # The counter span stays mounted (invisible at zero) so a first like
    # doesn't shift the neighbouring buttons under the pointer.
    test "zero counters reserve their space", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "stable row"})
      %{view: actions} = feed_actions(conn, post)

      like = "#post-actions-post-#{post.id}-like"
      html = actions |> element(like) |> render()
      assert html =~ "invisible"
      refute html =~ ~s(data-count="like")

      actions |> element(like) |> render_click()
      html = actions |> element(like) |> render()
      assert html =~ ~s(data-count="like")
      refute html =~ "invisible"
    end

    # The four controls spread across the full column width (X-style) rather
    # than clumping on the left, so the tap targets sit far apart.
    test "the action row spreads the buttons across the full width", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "spread wide"})
      %{view: actions} = feed_actions(conn, post)

      assert render(actions) =~ "justify-between"
    end

    test "your own like in another session fills the heart here too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "two tabs"})

      {:ok, feed_a, _html} = live(conn, ~p"/feed")
      {:ok, feed_b, _html} = live(conn, ~p"/feed")
      actions_a = find_live_child(feed_a, "post-actions-post-#{post.id}")
      actions_b = find_live_child(feed_b, "post-actions-post-#{post.id}")
      assert render(actions_b) =~ ~s(aria-pressed="false")

      actions_a |> element("#post-actions-post-#{post.id}-like") |> render_click()

      html = render(actions_b)
      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~r/data-count="like">\s*1\s*</
    end

    test "another user's like ticks the counter live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "watched"})
      %{view: actions} = feed_actions(conn, post)

      # Render once so the child is fully joined before the broadcast.
      assert render(actions) =~ "post-actions-post-#{post.id}-like"

      :ok = Posts.like_post(other_user(), post)

      html = render(actions)
      assert html =~ ~r/data-count="like">\s*1\s*</
    end
  end

  describe "the feed timeline with reposts" do
    test "a followee's repost arrives behind the pill with the reposted-by line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user(first_name: "Carla", last_name: "Carrier")
      insert(:follow, follower: user, followee: friend)
      post = create_post!(other_user(), %{body: "carried far"})

      {:ok, feed, _html} = live(conn, ~p"/feed")
      refute render(feed) =~ "carried far"

      :ok = Posts.repost_post(friend, post)

      assert feed |> element("#show-new-posts") |> render() =~ "Show 1 new post"
      html = feed |> element("#show-new-posts") |> render_click()
      assert html =~ "carried far"
      assert html =~ "Reposted by Carla Carrier"
    end

    test "your own repost prepends immediately", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      friend = other_user()
      insert(:follow, follower: user, followee: friend)
      post = create_post!(friend, %{body: "boost me"})

      {:ok, feed, _html} = live(conn, ~p"/feed")

      %{view: actions} = %{view: find_live_child(feed, "post-actions-post-#{post.id}")}
      actions |> element("#post-actions-post-#{post.id}-repost") |> render_click()

      html = render(feed)
      assert html =~ ~s(id="feed-repost-)
      assert html =~ "Reposted by"
    end
  end

  describe "/likes and /bookmarks" do
    test "redirect logged-out visitors to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/likes")
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/bookmarks")
    end

    test "list liked posts and switch tabs", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      liked = create_post!(other_user(), %{body: "I liked this"})
      marked = create_post!(other_user(), %{body: "I marked this"})
      :ok = Posts.like_post(user, liked)
      :ok = Posts.bookmark_post(user, marked)

      {:ok, view, html} = live(conn, ~p"/likes")
      assert html =~ "I liked this"
      refute html =~ "I marked this"

      html = view |> element("#tab-bookmarks") |> render_click()
      assert html =~ "I marked this"
      refute html =~ "I liked this"
    end

    test "unliking from the card removes it live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(other_user(), %{body: "soon gone"})
      :ok = Posts.like_post(user, post)

      {:ok, view, html} = live(conn, ~p"/likes")
      assert html =~ "soon gone"

      view
      |> find_live_child("post-actions-#{post.id}")
      |> element("#post-actions-#{post.id}-like")
      |> render_click()

      refute render(view) =~ "soon gone"
    end

    test "a like from another session prepends live", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(other_user(), %{body: "fresh like"})

      {:ok, view, html} = live(conn, ~p"/likes")
      refute html =~ "fresh like"

      :ok = Posts.like_post(user, post)
      assert render(view) =~ "fresh like"
    end
  end
end
