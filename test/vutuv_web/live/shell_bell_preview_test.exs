defmodule VutuvWeb.ShellBellPreviewTest do
  @moduledoc """
  The bell's hover preview: what the badge's number stands for, shown under the
  bell while the pointer rests on it, and marked read when it leaves.

  The gesture itself is the `BellPreview` hook's (a hover is not a LiveView
  binding), so these drive the two events it pushes. What they are really about
  is the promise the hook cannot keep on its own: **an event that arrives while
  the panel is open was never in it**, so the badge has to say so the moment the
  pointer leaves.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Activity

  @bell_badge ~s(a[title="Notifications"] span.bg-accent)
  @panel "#bell-preview"
  @row_marker "data-bell-preview-item"

  defp shell(conn, user) do
    live_isolated(conn, VutuvWeb.ShellLive, session: shell_session(user))
  end

  # One follower event, backdated so its stamp is deterministic and distinct.
  defp follower_event(user, at) do
    follow = insert(:follow, follower: insert(:user), followee: user)

    Vutuv.Repo.update_all(
      from(f in Vutuv.Social.Follow, where: f.id == ^follow.id),
      set: [inserted_at: at]
    )

    follow
  end

  test "the bell carries the unread count for the hook to read", %{conn: conn} do
    user = insert(:user)
    follower_event(user, ~N[2024-03-01 12:00:00])

    {:ok, view, _html} = shell(conn, user)

    assert has_element?(view, ~s(#bell-preview-host[data-unread="1"]))
    refute has_element?(view, @panel)
  end

  test "resting on the bell lists the events behind the number", %{conn: conn} do
    user = insert(:user)
    liker = insert(:user, first_name: "Ada", last_name: "Lovelace")
    insert(:follow, follower: liker, followee: user)

    {:ok, view, _html} = shell(conn, user)
    html = render_hook(view, "bell:preview", %{})

    assert html =~ "Ada Lovelace"
    assert html =~ "started following you."
    # Looking is not reading: the number stands until the pointer leaves.
    assert has_element?(view, @bell_badge, "1")
  end

  test "opening one row takes that event off the badge and leaves the rest", %{conn: conn} do
    # Clicking a row takes the member off this page, so the close event the
    # pointer would have sent never arrives — the row has to say for itself
    # which event it stands for, and the hook hands that back before it
    # navigates.
    user = insert(:user)
    follower_event(user, ~N[2024-03-01 12:00:00])
    opened = follower_event(user, ~N[2024-03-02 12:00:00])

    {:ok, view, _html} = shell(conn, user)
    render_hook(view, "bell:preview", %{})

    assert has_element?(
             view,
             ~s(a[data-seen-kind="follower"][data-seen-source-id="#{opened.id}"])
           )

    render_hook(view, "notify:seen", %{"kind" => "follower", "source_id" => opened.id})

    # By one, not to zero: the older follow was on the panel too and nobody
    # opened it.
    assert has_element?(view, @bell_badge, "1")
    assert Activity.unread_notification_count(user.id) == 1
  end

  test "moving the pointer away marks exactly what was shown as read", %{conn: conn} do
    user = insert(:user)
    follower_event(user, ~N[2024-03-01 12:00:00])

    {:ok, view, _html} = shell(conn, user)
    render_hook(view, "bell:preview", %{})
    render_hook(view, "bell:preview_close", %{})

    refute has_element?(view, @panel)
    refute has_element?(view, @bell_badge)
    assert Activity.unread_notification_count(user.id) == 0
  end

  test "an event arriving while the panel is open is back in the badge on close", %{conn: conn} do
    user = insert(:user)
    follower_event(user, ~N[2024-03-01 12:00:00])

    {:ok, view, _html} = shell(conn, user)
    assert render_hook(view, "bell:preview", %{}) =~ "started following you."

    # The member is reading the panel; somebody follows them right now.
    follower_event(user, ~N[2024-03-02 12:00:00])
    Activity.broadcast(user.id, :notifications_changed)

    render_hook(view, "bell:preview_close", %{})

    assert has_element?(view, @bell_badge, "1")
    assert Activity.unread_notification_count(user.id) == 1
  end

  test "a bell with nothing behind it opens no panel and reads nothing", %{conn: conn} do
    user = insert(:user)

    {:ok, view, _html} = shell(conn, user)
    render_hook(view, "bell:preview", %{})

    refute has_element?(view, @panel)

    # And a close without an open panel must not move the marker: the member
    # never saw anything, so a later event has to still be new.
    render_hook(view, "bell:preview_close", %{})
    follower_event(user, ~N[2024-03-01 12:00:00])

    assert Activity.unread_notification_count(user.id) == 1
  end

  test "the panel caps its list and says how many it is holding back", %{conn: conn} do
    user = insert(:user)

    for day <- 1..8 do
      follower_event(user, %{~N[2024-03-01 12:00:00] | day: day})
    end

    {:ok, view, _html} = shell(conn, user)
    render_hook(view, "bell:preview", %{})

    # Six rows of eight events, and the footer names the two it left out.
    assert has_element?(view, "[data-bell-preview-all]", "All notifications")
    assert row_count(view) == 6
    assert has_element?(view, "[data-bell-preview-more]", "2")

    # Leaving still empties the whole badge: the number was what the member
    # looked at, and the page keeps every one of the eight.
    render_hook(view, "bell:preview_close", %{})
    refute has_element?(view, @bell_badge)
  end

  test "the panel's German is written, not fuzzy-filled from something else", %{conn: conn} do
    # `gettext.extract --merge` fills a brand-new msgid with the translation of
    # whatever looked similar to it and nothing fails the build — "+%{count}
    # more" came back as "+%{formatted} weiterer Beitrag" the first time. So the
    # German of every string on this panel is asserted by name.
    user = insert(:user, locale: "de")

    insert(:follow,
      follower: insert(:user, first_name: "Ada", last_name: "Lovelace"),
      followee: user
    )

    for day <- 2..8, do: follower_event(user, %{~N[2024-03-01 12:00:00] | day: day})

    {:ok, view, _html} = shell(conn, user)
    html = render_hook(view, "bell:preview", %{})

    assert html =~ "Alle Mitteilungen"
    assert html =~ ~s(aria-label="Neue Mitteilungen")
    assert html =~ "weitere"
    assert html =~ "folgt Ihnen jetzt."
    refute html =~ "All notifications"
  end

  # Counted out of the markup rather than with a selector: `has_element?/2`
  # answers yes or no, and the number of rows is the assertion here.
  defp row_count(view) do
    view |> render() |> String.split(@row_marker) |> length() |> Kernel.-(1)
  end
end
