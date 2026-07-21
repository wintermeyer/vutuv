defmodule VutuvWeb.TagFollowControllerTest do
  use VutuvWeb.ConnCase, async: true

  # Following a tag (issue #872): the classic-page follow control on /tags/:slug.
  # Besides the create/delete round-trip these assert the pill's *rendered*
  # target (`data-to`, the CSRF-button convention app.js submits — the same
  # convention the person-follow pills use) points at the real /tag_follows
  # route, the guard against the route-mismatch class of bug that once 404ed
  # every settings Save button in production.

  alias Vutuv.Tags

  describe "create / delete" do
    test "POST follows the tag and DELETE unfollows it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag)

      conn = post(conn, ~p"/tag_follows", tag_follow: %{tag_id: tag.id})
      assert redirected_to(conn)
      assert Tags.tag_followed?(user, tag)

      conn = delete(recycle(conn), ~p"/tag_follows/#{tag.id}")
      assert redirected_to(conn)
      refute Tags.tag_followed?(user, tag)
    end

    test "a double follow is idempotent, not a 500", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag)

      conn = post(conn, ~p"/tag_follows", tag_follow: %{tag_id: tag.id})
      conn = post(recycle(conn), ~p"/tag_follows", tag_follow: %{tag_id: tag.id})
      assert redirected_to(conn)
      assert Tags.tag_followed?(user, tag)
    end

    test "a logged-out follow attempt 404s (RequireLoginOr404)", %{conn: conn} do
      tag = insert(:tag)
      conn = post(conn, ~p"/tag_follows", tag_follow: %{tag_id: tag.id})
      assert conn.status == 404
    end
  end

  describe "the tag page's follow control (issue #872)" do
    test "renders a pill whose CSRF button targets the real /tag_follows route", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = insert(:tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)
      assert html =~ ~s(data-to="/tag_follows?tag_follow[tag_id]=#{tag.id}")
      assert html =~ ~s(data-method="post")

      # Once following, the pill flips to the unfollow route for this tag.
      Tags.follow_tag(user, tag)
      html = conn |> recycle() |> get(~p"/tags/#{tag}") |> html_response(200)
      assert html =~ ~s(data-to="/tag_follows/#{tag.id}")
      assert html =~ ~s(data-method="delete")
    end

    test "shows the aggregate follower count", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      tag = insert(:tag)
      for _ <- 1..3, do: Tags.follow_tag(insert(:activated_user), tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)
      assert html =~ "follower"
    end

    test "a logged-out visitor sees no follow control but the page still renders", %{conn: conn} do
      tag = insert(:tag)
      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)
      refute html =~ ~s(data-to="/tag_follows)
    end
  end
end
