defmodule VutuvWeb.ShellLiveBrowserNotificationsTest do
  @moduledoc """
  Browser notifications (issue #1249). The shell is on every page and already
  holds the member's activity subscription, so it is what turns an arriving
  notification into the `notify:show` event the WebNotify hook raises a popup
  from.

  What these tests are really about is the **gate**: the feature is opt-in, and
  a member who never asked for it must never be pushed to — which is also the
  only thing standing between them and a permission prompt they did not want.
  So each push assertion has a matching `refute` with the switch off.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # `assert_push_event/4` waits 100 ms by default, and what is being waited
  # for here is a PubSub broadcast crossing into the shell process and back
  # out as a push — two hops, on a box running twenty cases at once. That
  # default made the suite flake (a red `mix precommit` on 2026-08-25 that
  # passed on re-run). The wait is not what any of these tests are about, so
  # it is generous.
  @push_timeout 2_000

  alias Vutuv.Activity
  alias Vutuv.Sessions

  defp session_for(user, extra) do
    {token, _session} = Sessions.start_session(user, build_conn(), alert: false)
    Map.merge(%{"session_token" => token}, extra)
  end

  defp mount_shell(conn, user, session_extra \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user, session_extra))

    view
  end

  defp like_notification(actor_name, extra \\ %{}) do
    Map.merge(
      %{
        kind: "like",
        actor_name: actor_name,
        actor_param: "anna_klein",
        actor_avatar: "/avatars/anna/thumb.jpg",
        text: "liked your post.",
        at: DateTime.utc_now()
      },
      extra
    )
  end

  describe "the opt-in gate" do
    test "a member who switched it on is pushed the arriving notification", %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      Activity.broadcast(user.id, {:new_notification, like_notification("Anna Klein")})

      # The actor's name is the popup's title and their verb phrase its body —
      # the same two halves the row under the bell reads as.
      assert_push_event(
        view,
        "notify:show",
        %{
          tag: "activity",
          title: "Anna Klein",
          body: "liked your post.",
          icon: "/avatars/anna/thumb.jpg"
        },
        @push_timeout
      )
    end

    test "a member who left it off is pushed nothing at all", %{conn: conn} do
      user = insert(:user)
      refute user.browser_notifications?

      view = mount_shell(conn, user)

      Activity.broadcast(user.id, {:new_notification, like_notification("Anna Klein")})

      # The badge still moves; only the popup is withheld.
      assert_push_event(view, "tab:badge", %{}, @push_timeout)
      refute_push_event(view, "notify:show", %{})
    end

    test "a new message is pushed under its own tag, naming neither sender nor text",
         %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      Activity.broadcast(user.id, {:new_message, %{conversation_id: Vutuv.UUIDv7.generate()}})

      assert_push_event(view, "notify:show", %{tag: "messages", url: "/messages"}, @push_timeout)
    end

    test "a new message reaches nobody who left the switch off", %{conn: conn} do
      user = insert(:user)
      view = mount_shell(conn, user)

      Activity.broadcast(user.id, {:new_message, %{conversation_id: Vutuv.UUIDv7.generate()}})

      refute_push_event(view, "notify:show", %{})
    end
  end

  describe "the wording" do
    test "an actorless notification puts its whole sentence in the title", %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      Activity.broadcast(
        user.id,
        {:new_notification,
         %{kind: "moderation", status: "upheld", text: "ignored", at: DateTime.utc_now()}}
      )

      # No name to head the popup with, so the sentence is the title and there
      # is no body — a placeholder name over one line would say less.
      assert_push_event(view, "notify:show", %{title: title, body: nil}, @push_timeout)
      assert title == "A report about your content was confirmed."
    end

    test "the line follows the reader's language, not the actor's", %{conn: conn} do
      user = insert(:user, browser_notifications?: true, locale: "de")
      # Where the shell reads it from: `VutuvWeb.Plug.Locale` resolves the
      # member's language per request and stores it in the session, which is
      # what `LiveLocale.put_viewer/1` re-applies inside the socket. A test that
      # only set the column would prove nothing about what a member sees.
      view = mount_shell(conn, user, %{"locale" => "de"})

      Activity.broadcast(user.id, {:new_notification, like_notification("Anna Klein")})

      assert_push_event(view, "notify:show", %{body: body}, @push_timeout)
      assert body == "gefällt Ihr Beitrag."
    end
  end

  describe "where the popup leads" do
    test "to the thing it just named, not to the list", %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      post = insert(:post, user: user)
      view = mount_shell(conn, user)

      Activity.broadcast(
        user.id,
        {:new_notification, like_notification("Anna Klein", %{post_id: post.id})}
      )

      # A popup is raised precisely when the member is NOT looking at vutuv, so
      # this is the surface where landing on a list to hunt costs most. The
      # destination comes from the same function the row under the bell uses.
      assert_push_event(view, "notify:show", %{url: url}, @push_timeout)
      assert url == "/#{user.username}/posts/#{post.id}"
    end

    test "to the notifications list when the kind has no page of its own",
         %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      Activity.broadcast(
        user.id,
        {:new_notification, %{kind: "moderation", status: "upheld", at: DateTime.utc_now()}}
      )

      assert_push_event(view, "notify:show", %{url: "/notifications"}, @push_timeout)
    end
  end

  describe "the test notification" do
    test "travels the same path a real one does", %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      render_hook(view, "notify:test", %{})

      # `test: true` is what lets the hook show it although the member is
      # plainly looking at the settings page; without it the away-gate would
      # swallow every press and the button would do nothing at all.
      assert_push_event(
        view,
        "notify:show",
        %{tag: "test", test: true, title: title},
        @push_timeout
      )

      assert title == "Test notification"
    end

    test "is sent even before the switch has been saved", %{conn: conn} do
      # Ticking the box asks this browser for permission on the spot, so the
      # useful moment to press "test" is right then - with the preference still
      # off in the database. Every automatic push is gated on it; this one is
      # not, because the member asked for it by name.
      user = insert(:user)
      refute user.browser_notifications?

      view = mount_shell(conn, user)
      render_hook(view, "notify:test", %{})

      assert_push_event(view, "notify:show", %{tag: "test"}, @push_timeout)
    end

    test "reaches nobody who is not logged in", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

      render_hook(view, "notify:test", %{})

      refute_push_event(view, "notify:show", %{})
    end
  end

  describe "the per-browser permission prompt" do
    test "renders for a member who switched the feature on", %{conn: conn} do
      user = insert(:user, browser_notifications?: true)
      view = mount_shell(conn, user)

      assert has_element?(view, "#web-notify[data-enabled=true]")
      # Shipped hidden by the plain attribute (never a display utility) — the
      # hook takes it off only where this browser has not been asked yet.
      assert has_element?(view, "[data-notify-prompt][hidden]")
      assert has_element?(view, "[data-notify-allow]")
    end

    test "is absent for a member who left the feature off", %{conn: conn} do
      user = insert(:user)
      view = mount_shell(conn, user)

      assert has_element?(view, "#web-notify[data-enabled=false]")
      refute has_element?(view, "[data-notify-prompt]")
    end

    test "appears without a reload when another session switches the feature on",
         %{conn: conn} do
      user = insert(:user)
      view = mount_shell(conn, user)

      refute has_element?(view, "[data-notify-prompt]")

      # What SettingsController.update_notifications broadcasts on save. The
      # switch is the member's and travels with the account, so a tab on
      # another machine has to learn about it — and then ask its own browser.
      Activity.broadcast(user.id, {:browser_notifications_pref, true})

      assert has_element?(view, "#web-notify[data-enabled=true]")
      assert has_element?(view, "[data-notify-prompt]")
    end
  end
end
