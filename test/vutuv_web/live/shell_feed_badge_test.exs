defmodule VutuvWeb.ShellFeedBadgeTest do
  @moduledoc """
  The "Feed" nav item's unread badge: what arrived in the member's feed while
  they were reading something else, live over PubSub.

  The badge exists because the feed's own "new posts" pill only speaks while the
  reader is standing on /feed — walk over to a profile and everything that lands
  is silent. What it counts is the same figure on every page, /feed included:
  posts that arrived and have not been put in front of the reader yet. So the
  rules under test are that an arrival raises it wherever the member is, that
  the press unfolding the pill takes it off again, and that a read in one tab
  empties it in the others.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Social

  # Only the Feed nav link carries `data-feed-count`, so this cannot pick up the
  # bell's or the envelope's badge.
  @feed_badge ~s(a[data-feed-count] span.bg-accent)
  @tab_badge ~s(nav[data-nav-bar="tabs"] a[href="/feed"] span.bg-accent)

  # The reader, marked read a minute ago: the count's window opens the second
  # after the marker, so a member marked read "now" would not be told about a
  # post this test creates in the same second.
  defp reader do
    insert(:activated_user,
      feed_read_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)
    )
  end

  defp followed_author(reader) do
    author = insert(:activated_user)
    Social.follow(reader, author.id)
    author
  end

  defp shell(conn, user, path) do
    live_isolated(conn, VutuvWeb.ShellLive, session: shell_session(user, %{"path" => path}))
  end

  # What `Vutuv.Posts.create_post/2` broadcasts to every follower's topic, for
  # the cases that need an arrival with no post behind it — one the reader may
  # not see, one carrying a nil id. Where the fan-out itself is the promise,
  # write the post instead.
  defp announce(view, post) do
    send(
      view.pid,
      {:new_post, %{post_id: post.id, author_id: post.user_id, at: post.inserted_at}}
    )
  end

  test "counts what reached the feed while the member was on another page", %{conn: conn} do
    reader = reader()
    author = followed_author(reader)
    create_post!(author, %{body: "arrived while you were away"})

    {:ok, view, _html} = shell(conn, reader, "/#{reader.username}")

    assert has_element?(view, @feed_badge, "1")
    # The phone's bottom tab bar carries the same figure.
    assert has_element?(view, @tab_badge, "1")
  end

  test "counts on the feed too, for as long as the pill is holding the posts", %{conn: conn} do
    reader = reader()
    author = followed_author(reader)

    {:ok, view, _html} = shell(conn, reader, "/feed")

    # A shell mounting on /feed starts empty, and here that is the true figure
    # rather than a rule: the page's own mount has just written the marker.
    refute has_element?(view, @feed_badge)

    # Behind the pill is not in front of the reader, so the nav item says here
    # what it would say on their profile — same source, same number.
    create_post!(author, %{body: "arrived while reading the feed"})

    assert has_element?(view, @feed_badge, "1")
    assert has_element?(view, @tab_badge, "1")

    # And it stops the moment they are shown: what the feed writes when the pill
    # is unfolded (`feed_marks_read_test.exs` drives the press itself) empties
    # the badge from here as well.
    :ok = Posts.mark_feed_read(reader)

    refute has_element?(view, @feed_badge)
  end

  test "a look-alike slug is not the feed", %{conn: conn} do
    reader = reader()
    author = followed_author(reader)
    create_post!(author, %{body: "arrived while you were away"})

    {:ok, view, _html} = shell(conn, reader, "/feedback-anna")

    assert has_element?(view, @feed_badge, "1")
  end

  # Through the real write, not `announce/2`: this is the one test standing in
  # for what a reader actually does, and a hand-sent message would leave the
  # fan-out itself — whether pressing "Post" produces one at all — unproven.
  test "a post arriving while the member is elsewhere raises the badge", %{conn: conn} do
    reader = reader()
    author = followed_author(reader)

    {:ok, view, _html} = shell(conn, reader, "/#{reader.username}")
    refute has_element?(view, @feed_badge)

    create_post!(author, %{body: "arrived while reading a profile"})

    assert has_element?(view, @feed_badge, "1")
  end

  test "the member's own post never badges them", %{conn: conn} do
    reader = reader()

    {:ok, view, _html} = shell(conn, reader, "/#{reader.username}")

    # Writing a reply from a post's permalink page is the real case: the member
    # is away from the feed, so nothing marks it read, and their own words
    # arrive on their own activity topic like anybody else's.
    #
    # Two layers hold this and the outer one is here: the shell skips the
    # recount for its own author id, and `Posts.unread_feed_count/1` rejects the
    # entry anyway (`feed_unread_count_test.exs` calibrates that half). This
    # pins the promise the reader sees.
    announce(view, create_post!(reader, %{body: "I wrote this myself"}))

    refute has_element?(view, @feed_badge)
  end

  test "reading the feed in another tab empties the badge here", %{conn: conn} do
    reader = reader()
    author = followed_author(reader)
    create_post!(author, %{body: "arrived while you were away"})

    {:ok, view, _html} = shell(conn, reader, "/#{reader.username}")
    assert has_element?(view, @feed_badge, "1")

    # What the other tab's feed mount broadcasts.
    :ok = Posts.mark_feed_read(reader)

    refute has_element?(view, @feed_badge)

    # And the next arrival must not resurrect what that tab just read. What
    # holds that is `unread_feed_count/1`'s id clause, which re-reads the
    # member: this socket's own copy of them is as old as its mount, and
    # `feed_unread_count_test.exs` pins the two clauses apart.
    send(view.pid, {:new_post, %{post_id: nil, author_id: author.id, at: nil}})

    refute has_element?(view, @feed_badge)
  end
end
