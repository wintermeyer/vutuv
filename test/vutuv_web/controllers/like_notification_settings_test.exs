defmodule VutuvWeb.LikeNotificationSettingsTest do
  use VutuvWeb.ConnCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Repo

  describe "/settings/notifications" do
    test "offers the like cap, saves it through the rendered form and resets it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/notifications") |> html_response(200)
      assert html =~ ~s(id="like-notifications")
      assert html =~ ~s(<option selected value="50">)
      # The card's form posts where the route really is.
      assert html =~ ~s(action="/settings/notifications")

      conn =
        put(conn, ~p"/settings/notifications", %{"user" => %{"like_notification_cap" => "none"}})

      assert redirected_to(conn) == ~p"/settings/notifications"
      assert Repo.reload!(user).like_notification_cap == "none"

      conn = conn |> recycle() |> post(~p"/settings/like_notifications/reset")
      assert redirected_to(conn) == ~p"/settings/notifications"
      assert Repo.reload!(user).like_notification_cap == nil
    end

    test "refuses a cap that is not one of the jumps", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/notifications", %{"user" => %{"like_notification_cap" => "37"}})

      assert html_response(conn, 422)
      assert Repo.reload!(user).like_notification_cap == nil
    end

    test "names the cap in German", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/notifications")
        |> html_response(200)

      assert html =~ "Likes eines Beitrags melden bis"
      assert html =~ "Kein Limit"
    end
  end

  describe "muting one post" do
    test "the author's ⋯ menu mutes and unmutes it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "mine"})

      html = conn |> get(Vutuv.Posts.path(%{post | user: user})) |> html_response(200)
      assert html =~ ~s(href="/posts/#{post.id}/notifications_mute")

      conn = put(conn, ~p"/posts/#{post.id}/notifications_mute")
      assert redirected_to(conn) == Vutuv.Posts.path(%{post | user: user})
      assert Repo.reload!(post).notifications_muted_at

      conn = conn |> recycle() |> delete(~p"/posts/#{post.id}/notifications_mute")
      assert redirected_to(conn)
      refute Repo.reload!(post).notifications_muted_at
    end

    test "somebody else's post is a 404", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      post = create_post!(insert(:activated_user), %{body: "theirs"})

      conn = put(conn, ~p"/posts/#{post.id}/notifications_mute")
      assert html_response(conn, 404)
      refute Repo.reload!(post).notifications_muted_at
    end
  end
end
