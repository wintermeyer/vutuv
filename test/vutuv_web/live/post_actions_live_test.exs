defmodule VutuvWeb.PostActionsLiveTest do
  @moduledoc """
  The per-card action bar: like/bookmark/repost toggles and the repost lock on
  restricted posts, plus the /likes and /bookmarks pages fed by it.

  On a LiveView host (the feed) the bar is the in-process
  `VutuvWeb.PostLive.ActionsComponent`, driven straight through the host view —
  no nested child LiveView (the change that killed the per-card flashing and the
  per-card PubSub subscriptions). The standalone `VutuvWeb.PostLive.Actions`
  LiveView still backs the dead controller pages and keeps its live counters; it
  is exercised in isolation below.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  # The bar is part of the feed's own DOM now, so the feed view itself drives it
  # (the button's `phx-target` routes the click to its component).
  defp feed_actions(conn, _post) do
    {:ok, feed, _html} = live(conn, ~p"/feed")
    %{view: feed, feed: feed}
  end

  describe "no nested action LiveView (flash + PubSub fix)" do
    test "the feed renders the action bar inline, not as a child LiveView", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "inline bar"})

      {:ok, feed, _html} = live(conn, ~p"/feed")

      # The bar lives in the feed's own DOM (a LiveComponent), so there is no
      # per-card child LiveView to re-mount (flash) when the feed re-renders a
      # stream, and no per-card "post:<id>" subscription.
      refute find_live_child(feed, "post-actions-post-#{post.id}")
      assert has_element?(feed, "#post-actions-post-#{post.id}-like")

      # A like still updates the card in place, handled by the feed process.
      feed |> element("#post-actions-post-#{post.id}-like") |> render_click()
      assert render(feed) =~ ~r/data-count="like">\s*1\s*</
      assert %{likes: 1} = Posts.engagement_counts(post.id)
    end
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

    test "the reply button links to the reply page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "discussable"})
      %{view: actions} = feed_actions(conn, post)

      html = actions |> element("#post-actions-post-#{post.id}-reply") |> render()
      assert html =~ ~s(href="/posts/#{post.id}/reply")
      refute html =~ ~s(data-count="reply")
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

    # On a LiveView host the bar no longer subscribes to the post topic (the
    # "minimum PubSub" trade-off), so a like by another session / another user
    # is not reflected live — it refreshes on reload. The standalone bar on the
    # dead pages still ticks live; the underlying broadcast is covered by the
    # "engagement broadcasts" cases below.
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

      feed |> element("#post-actions-post-#{post.id}-repost") |> render_click()

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

      view |> element("#post-actions-#{post.id}-like") |> render_click()

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

  describe "the action bar reacts to deletion" do
    # On the feed the whole card is dropped, but on the dead permalink/profile
    # pages the bar is the only part that can react — test it in isolation.
    test "empties itself when its post is deleted" do
      user = other_user()
      post = create_post!(user, %{body: "doomed"})

      {:ok, bar, html} =
        live_isolated(build_conn(), VutuvWeb.PostLive.Actions,
          session: %{
            "post_id" => post.id,
            "user_id" => user.id,
            "id" => "post-actions-#{post.id}",
            "locale" => "en"
          }
        )

      assert html =~ ~s(phx-click="toggle")

      {:ok, _} = Posts.delete_post(post)
      _ = :sys.get_state(bar.pid)
      refute render(bar) =~ ~s(phx-click="toggle")
    end
  end

  describe "engagement broadcasts" do
    # The action bar learns about the actor's *own* toggle over the post topic
    # (so it no longer has to subscribe to the actor's whole activity firehose
    # just to re-sync its own filled-in flags). The post-counter event therefore
    # names the actor via :by_user_id, alongside the absolute counts.
    test "a toggle tags the post-topic counter with the acting user" do
      author = other_user()
      liker = other_user()
      post = create_post!(author, %{body: "tagged"})

      Posts.subscribe_post(post.id)
      :ok = Posts.like_post(liker, post)

      assert_receive {:post_counters, %{likes: 1, post_id: post_id, by_user_id: by_user_id}}
      assert post_id == post.id
      assert by_user_id == liker.id
    end

    # A non-toggle counter refresh (a reply ticking the parent's count) carries
    # no actor, so a bar treats it as counts-only and never reloads flags.
    test "a reply-count refresh carries no acting user" do
      author = other_user()
      post = create_post!(author, %{body: "parent"})

      Posts.subscribe_post(post.id)
      {:ok, _} = Posts.create_reply(other_user(), post, %{body: "child"})

      assert_receive {:post_counters, %{replies: 1} = payload}
      refute Map.has_key?(payload, :by_user_id)
    end
  end

  describe "preloaded engagement" do
    # A list page (the feed) pre-loads engagement once and hands each card its
    # own via the session, so the bar skips its mount query. Prove the bar
    # renders exactly what it was handed by passing a like count no query could
    # produce (the post has zero likes).
    test "renders engagement handed in via the session instead of querying" do
      user = other_user()
      post = create_post!(user, %{body: "preloaded"})

      passed = %{
        likes: 999,
        bookmarks: 0,
        reposts: 0,
        replies: 0,
        liked?: true,
        bookmarked?: false,
        reposted?: false,
        restricted?: false,
        author_id: user.id,
        id: post.id
      }

      {:ok, _bar, html} =
        live_isolated(build_conn(), VutuvWeb.PostLive.Actions,
          session: %{
            "post_id" => post.id,
            "user_id" => user.id,
            "id" => "post-actions-#{post.id}",
            "locale" => "en",
            "engagement" => passed
          }
        )

      assert html =~ ~r/data-count="like">\s*999\s*</
      assert html =~ ~s(aria-pressed="true")
    end

    # Without an engagement in the session (a lone card on a dead page), the bar
    # falls back to loading its own — here the post genuinely has one like.
    test "falls back to its own query when the session carries none" do
      user = other_user()
      post = create_post!(user, %{body: "self-loaded"})
      :ok = Posts.like_post(other_user(), post)

      {:ok, _bar, html} =
        live_isolated(build_conn(), VutuvWeb.PostLive.Actions,
          session: %{
            "post_id" => post.id,
            "user_id" => user.id,
            "id" => "post-actions-#{post.id}",
            "locale" => "en"
          }
        )

      assert html =~ ~r/data-count="like">\s*1\s*</
    end
  end
end
