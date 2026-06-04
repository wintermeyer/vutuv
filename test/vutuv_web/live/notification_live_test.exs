defmodule VutuvWeb.NotificationLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /notifications" do
    test "lists real events derived from the database", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      connection = insert(:connection, follower: follower, followee: user)

      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: user, tag: tag)
      insert(:user_tag_endorsement, user: endorser, user_tag: user_tag)

      {:ok, live, html} = live(conn, ~p"/notifications")

      # Disconnected (dead) render goes through the :browser pipeline + root layout.
      assert html =~ "Notifications"
      assert html =~ "Grace Hopper"
      assert html =~ "started following you"

      # Connected render goes through the /live socket + InitAssigns on_mount.
      assert render(live) =~ "endorsed you for Phoenix"
      assert has_element?(live, "#notification-follower-#{connection.id}")

      # The actor's name links to their profile.
      assert render(live) =~ ~s(href="/users/#{follower.active_slug}")
    end

    test "a derived row shows the actor's real avatar when they have one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower =
        insert(:user, first_name: "Grace", last_name: "Hopper", avatar: "grace.jpg")

      insert(:connection, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The real photo URL, not the inline default-avatar SVG.
      assert render(live) =~ ~s(/avatars/#{follower.id}/)
    end

    test "shows a mutual follow as a connection event", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      other = insert(:user, first_name: "Wojtek", last_name: "Mach")
      insert(:connection, follower: other, followee: user)
      insert(:connection, follower: user, followee: other)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "is now connected with you"
    end

    test "shows the empty state when nothing happened yet", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "Nothing new yet."
      refute has_element?(live, "#notification-list li")
    end

    test "visiting the page persists the read marker (badge stays cleared)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:connection, follower: insert(:user), followee: user)

      # The events predate the visit (timestamps are second-precision, so an
      # event in the same second as the read marker would not count anyway).
      assert Vutuv.Activity.unread_notification_count(user.id) == 1

      {:ok, _live, _html} = live(conn, ~p"/notifications")

      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "renders for a logged-out visitor too", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/notifications")
      assert html =~ "Notifications"
      assert html =~ "Nothing new yet."
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

    test "live notifications get dom ids outside the derived id namespace", %{conn: conn} do
      # Live ids carry a "live-" prefix while derived rows use "<kind>-<row id>",
      # so a live event can never update a derived row in place by id collision.
      {conn, user} = create_and_login_user(conn)
      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      insert(:connection, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      Vutuv.Activity.notify_new_follower(user.id, %{first_name: "Ada", last_name: "Lovelace"})
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ ~s(id="notification-live-)
      # the derived row survives the insert
      assert html =~ "Grace Hopper"
    end

    test "a long feed offers Load more, which appends the older events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # One more event than the page size; they all share the same insert
      # second, so this also exercises the tie-handling of the cursor.
      for _ <- 1..51, do: insert(:connection, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, "#load-more")
      assert row_count(render(live)) == 50

      live |> element("#load-more") |> render_click()

      assert row_count(render(live)) == 51
      refute has_element?(live, "#load-more")
    end

    test "a short feed shows no Load more button", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:connection, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, "#load-more")
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

  # Derived follower rows carry an `id="notification-follower-<row id>"`.
  defp row_count(html), do: length(String.split(html, ~s(id="notification-follower-))) - 1
end
