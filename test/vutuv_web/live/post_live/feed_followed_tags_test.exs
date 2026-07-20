defmodule VutuvWeb.PostLive.FeedFollowedTagsTest do
  use VutuvWeb.ConnCase, async: true

  # The feed's followed-tag surfaces (issue #872): the reload-free "Tags you
  # follow" rail (chips + ✕ unfollow) and the "Who to follow" rail leading with
  # people endorsed for tags the viewer follows.

  import Phoenix.LiveViewTest

  alias Vutuv.Tags

  describe "Tags you follow rail" do
    test "renders the followed-tag chips and unfollows one with no reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      Tags.follow_tag(user, tag)

      {:ok, view, html} = live(conn, ~p"/feed")
      assert html =~ "Tags you follow"
      assert has_element?(view, "#followed-tag-#{tag.id}")

      view
      |> element(~s(#followed-tag-#{tag.id} button[phx-click="unfollow_tag"]))
      |> render_click()

      refute has_element?(view, "#followed-tag-#{tag.id}")
      refute Tags.tag_followed?(user, tag)
    end

    test "the rail is absent when the member follows no tags", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/feed")
      refute has_element?(view, "#followed-tags")
    end
  end

  describe "Who to follow leads with people from followed tags" do
    test "a member endorsed for a followed tag appears in the who-to-follow rail", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      Tags.follow_tag(user, tag)

      candidate = insert(:activated_user, first_name: "Tagged", last_name: "Person")
      ut = insert(:user_tag, user: candidate, tag: tag)
      insert(:user_tag_endorsement, user_tag: ut, user: insert(:activated_user))

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert has_element?(view, "#who-to-follow")
      assert render(view) =~ "Tagged Person"
    end
  end
end
