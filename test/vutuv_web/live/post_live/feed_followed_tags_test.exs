defmodule VutuvWeb.PostLive.FeedFollowedTagsTest do
  use VutuvWeb.ConnCase, async: true

  # The feed's followed-tag surface (issue #872): the reload-free "Tags you
  # follow" rail — chips + a ✕ unfollow. The rail's other half, a "Who to
  # follow" card led by people endorsed for those tags, is gone: that slot is
  # the "New here" welcome card now (see FeedNewcomersTest). The people half of
  # #872 still lives on the profile's own suggestion card.

  import Phoenix.LiveViewTest

  alias Vutuv.Tags

  # The discovery rail renders with the page again (the v7.200.3 laziness was
  # undone — see FeedRailsTest); the helper name survives at the call sites.
  defp live_feed_with_rails(conn) do
    {:ok, view, html} = live(conn, ~p"/feed")
    {:ok, view, html}
  end

  describe "Tags you follow rail" do
    test "renders the followed-tag chips and unfollows one with no reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag)
      Tags.follow_tag(user, tag)

      {:ok, view, html} = live_feed_with_rails(conn)
      assert html =~ "Tags you follow"
      assert has_element?(view, "#followed-tag-#{tag.id}")

      view
      |> element(~s(#followed-tag-#{tag.id} button[phx-click="unfollow_tag"]))
      |> render_click()

      refute has_element?(view, "#followed-tag-#{tag.id}")
      refute Tags.tag_followed?(user, tag)
    end

    # It used to be absent with no tags followed, which was right while the card
    # was a list and nothing else. It carries the follow field now (2026-08-28),
    # so hiding it until a tag is already followed would put the *first* follow
    # behind a tag page — the long way round the field exists to remove.
    test "the card stands even with no tags followed, because it is the way in", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live_feed_with_rails(conn)

      assert has_element?(view, "#followed-tags")

      assert has_element?(
               view,
               ~s(#rail-followed_tags form input[name="name"])
             )
    end
  end
end
