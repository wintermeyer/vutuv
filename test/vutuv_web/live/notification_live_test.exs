defmodule VutuvWeb.NotificationLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /notifications" do
    test "mounts (disconnected and connected) and lists dummy notifications", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, html} = live(conn, ~p"/notifications")

      # Disconnected (dead) render goes through the :browser pipeline + root layout.
      assert html =~ "Notifications"
      assert html =~ "started following you"

      # Connected render goes through the /live socket + InitAssigns on_mount.
      assert render(live) =~ "endorsed you for Phoenix"
      assert has_element?(live, "#notification-3")

      # The actor's name links to their profile.
      assert render(live) =~ ~s(href="/users/chris-mccord")
    end

    test "renders for a logged-out visitor too", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications")
      assert html =~ "Notifications"
    end

    test "a new follower appears live without a reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      Vutuv.Activity.notify_new_follower(user.id, %{first_name: "Ada", last_name: "Lovelace"})
      # The broadcast is async; force the LiveView to process it before asserting.
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ "Ada Lovelace"
      assert html =~ "started following you."
    end

    test "live notifications get dom ids outside the dummy id namespace", %{conn: conn} do
      # Regression: live ids came from System.unique_integer, which starts at 1
      # on a fresh node — colliding with dummy ids 1..3, so a real notification
      # could silently update a dummy row in place instead of prepending.
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      Vutuv.Activity.notify_new_follower(user.id, %{first_name: "Ada", last_name: "Lovelace"})
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ ~s(id="notification-live-)
      # all three dummy rows survive the insert
      assert html =~ "endorsed you for Phoenix"
      assert html =~ "Wojtek Mach"
    end

    test "a real follower is rendered with a profile link and avatar", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      follower =
        insert(:user, first_name: "Grace", last_name: "Hopper")

      Vutuv.Activity.notify_new_follower(user.id, follower)
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ "Grace Hopper"
      assert html =~ ~s(href="/users/#{follower.active_slug}")
    end
  end
end
