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
      assert render(live) =~ ~s(href="/#{follower.active_slug}")
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

    test "shows a reply as a reply event, but not a self-reply", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user, first_name: "Joe", last_name: "Armstrong")
      parent = insert(:post, user: user)

      ref =
        insert(:post_reply,
          post: insert(:post, user: replier),
          parent_post: parent,
          parent_author: user
        )

      insert(:post_reply,
        post: insert(:post, user: user),
        parent_post: parent,
        parent_author: user
      )

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "replied to your post"
      assert render(live) =~ "Joe Armstrong"
      assert has_element?(live, "#notification-reply-#{ref.id}")
      # The self-reply derives no row.
      assert row_count(render(live), "reply") == 1
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

    test "a live event while on the page re-marks read so the shell badge stays 0", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The shell listens on the user topic and zeroes the bell badge whenever
      # notifications are marked read. Subscribe after mount (the mount-time
      # mark already fired) so we only see the read triggered by the new event.
      Vutuv.Activity.subscribe(user.id)

      # A real follow lands while the user is watching: the row makes it unread,
      # and the live broadcast renders it on the open page.
      follower = insert(:user, first_name: "Ada", last_name: "Lovelace")
      insert(:connection, follower: follower, followee: user)
      Vutuv.Activity.notify_new_follower(user.id, follower)
      _ = :sys.get_state(live.pid)

      # Showing the event live must advance the read marker, which broadcasts
      # :notifications_read and keeps the bell badge at zero rather than +1.
      assert_receive :notifications_read
      assert Vutuv.Activity.unread_notification_count(user.id) == 0
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

    test "a long feed offers a numbered Load more, which appends the older events", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # Two more than two page sizes; they all share the same insert second,
      # so this also exercises the tie-handling of the cursor. 52 remaining
      # after page one makes the batch size and the remainder differ, which
      # pins the order of the two numbers in the button label.
      for _ <- 1..102, do: insert(:connection, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The label says what the next click loads and how much is left in total.
      assert live |> element("#load-more") |> render() =~ "Load 50 of 52 more"
      assert row_count(render(live)) == 50

      live |> element("#load-more") |> render_click()

      assert row_count(render(live)) == 100
      assert live |> element("#load-more") |> render() =~ "Load 2 of 2 more"

      live |> element("#load-more") |> render_click()

      assert row_count(render(live)) == 102
      refute has_element?(live, "#load-more")
    end

    test "the Load more label falls back to plain text when the snapshot runs out", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # `remaining` is a mount-time count snapshot, while more?/cursor track the
      # live database. Seed 51 events so the snapshot is 51 (page one shows 50,
      # one remaining) ...
      for i <- 1..51 do
        c = insert(:connection, follower: insert(:user), followee: user)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], -i))
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert live |> element("#load-more") |> render() =~ "Load 1 of 1 more"

      # ... then slip many older events in behind the snapshot. The next page
      # pulls 50 of them, driving `remaining` to zero while more? is still true.
      for i <- 1..60 do
        c = insert(:connection, follower: insert(:user), followee: user)
        backdate_connection(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], -100 - i))
      end

      live |> element("#load-more") |> render_click()

      # The button still loads more, so it must not advertise "Load 0 of 0 more".
      assert has_element?(live, "#load-more")
      label = live |> element("#load-more") |> render()
      refute label =~ "0 of 0"
      assert label =~ "Load more"
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
      assert html =~ ~s(href="/#{follower.active_slug}")
    end
  end

  # Derived rows carry an `id="notification-<kind>-<row id>"`.
  defp row_count(html, kind \\ "follower"),
    do: length(String.split(html, ~s(id="notification-#{kind}-))) - 1

  # Connection inserted_at has second precision; backdating to distinct seconds
  # gives the feed a deterministic newest-first order to paginate through.
  defp backdate_connection(%Vutuv.Social.Connection{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(c in Vutuv.Social.Connection, where: c.id == ^id),
      set: [inserted_at: at]
    )
  end
end
