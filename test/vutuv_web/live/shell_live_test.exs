defmodule VutuvWeb.ShellLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  @bell_badge ~s(a[title="Notifications"] span.bg-accent)
  @mail_badge ~s(a[title="Messages"] span.bg-accent)

  defp session_for(user, extra \\ %{}) do
    Map.merge(
      %{
        "user_id" => user.id,
        "user_name" => "Stefan Wintermeyer",
        "user_param" => "stefan"
      },
      extra
    )
  end

  defp user_with_unread_notification do
    user = insert(:user)
    insert(:follow, follower: insert(:user), followee: user)
    user
  end

  # An accepted conversation holding one message the user has not read.
  defp with_unread_message(user) do
    other = insert(:user)
    conversation = insert_conversation_between(other, user)
    {:ok, _} = Vutuv.Chat.send_message(other, conversation.id, "unread ping")
    user
  end

  test "renders the shell nav with the real unread notification count", %{conn: conn} do
    user = user_with_unread_notification()
    {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert html =~ "vutuv"
    assert has_element?(view, "#app-shell")
    # one unread follower event; no conversations, so no messages badge
    assert has_element?(view, @bell_badge, "1")
    refute has_element?(view, @mail_badge)
  end

  test "renders the real unread conversation count", %{conn: conn} do
    user = with_unread_message(insert(:user))
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, @mail_badge, "1")
  end

  test "a new-message event bumps the messages badge", %{conn: conn} do
    user = with_unread_message(insert(:user))
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    send(view.pid, {:new_message, %{conversation_id: "x"}})

    assert has_element?(view, @mail_badge, "2")
  end

  test "marking messages read clears the messages badge", %{conn: conn} do
    user = with_unread_message(insert(:user))
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    send(view.pid, :messages_read)

    refute has_element?(view, @mail_badge)
  end

  test "already-read events don't count toward the badge", %{conn: conn} do
    user = user_with_unread_notification()
    Vutuv.Activity.mark_notifications_read(user.id)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    refute has_element?(view, @bell_badge)
  end

  test "shows the user's avatar in the top bar when they have one", %{conn: conn} do
    user = insert(:user)
    session = session_for(user, %{"user_avatar" => "/avatars/#{user.id}/Stefan%20W_thumb.jpg"})
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    assert has_element?(view, ~s(a[title="Stefan Wintermeyer"] img))
    refute has_element?(view, ~s(a[title="Stefan Wintermeyer"]), "SW")
  end

  test "falls back to initials when the user has no avatar", %{conn: conn} do
    user = insert(:user)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert has_element?(view, ~s(a[title="Stefan Wintermeyer"]), "SW")
    refute has_element?(view, ~s(a[title="Stefan Wintermeyer"] img))
  end

  test "a logged-in dead render carries the avatar through shell_session", %{conn: conn} do
    # End to end through the app layout: LayoutHTML.shell_session/1 must hand
    # the avatar URL to the embedded shell on classic controller pages too.
    {conn, user} = create_and_login_user(conn)

    {:ok, user} =
      Vutuv.Repo.update(Ecto.Changeset.change(user, avatar: "me.jpg"))

    # The search page renders no avatars of its own, so the only avatar URL in
    # the response is the one the shell chrome puts in the top bar.
    response = conn |> get(~p"/search") |> html_response(200)
    assert response =~ ~s(/avatars/#{user.id}/)
  end

  test "shows a Log in button when logged out", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})
    assert has_element?(view, "a", "Log in")
    refute has_element?(view, "span.bg-accent")
  end

  test "the anonymous bottom bar offers Log in instead of dead-end tabs", %{conn: conn} do
    # Messages and Alerts only redirect a visitor to the login page, so the
    # mobile tab bar replaces them with a Log in tab while logged out.
    {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

    assert has_element?(view, ~s(nav a[href="/login"]))
    refute html =~ ~s(href="/messages")
    refute html =~ ~s(href="/notifications")
  end

  test "the logged-in bottom bar keeps Messages and Alerts", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/search") |> html_response(200)

    assert html =~ ~s(href="/messages")
    assert html =~ ~s(href="/notifications")
  end

  test "renders the anonymous shell for a stale cookie user_id with no profile data", %{
    conn: conn
  } do
    # Phoenix.LiveView.Static merges the raw browser session UNDER the curated
    # :session (LayoutHTML.shell_session/1). A cookie pointing at a
    # since-deleted or UUID-re-keyed account makes shell_session/1 return %{}
    # (no current_user), but the browser session's bare `user_id` still leaks
    # in here without the profile fields. The shell must treat that as logged
    # out, not render the logged-in chrome — which needs the `user_param` only
    # shell_session supplies — and crash on ~p"/#{nil}".
    stale = %{"user_id" => Vutuv.UUIDv7.generate()}
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: stale)

    assert has_element?(view, "a", "Log in")
    refute has_element?(view, ~s(a[title] img))
    refute has_element?(view, "span.bg-accent")
  end

  test "a new-notification event bumps the bell badge", %{conn: conn} do
    user = user_with_unread_notification()
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    send(view.pid, {:new_notification, %{text: "hi"}})

    assert has_element?(view, @bell_badge, "2")
  end

  test "the badge for the page being viewed starts at zero (no read-broadcast race)", %{
    conn: conn
  } do
    user = with_unread_message(user_with_unread_notification())
    session = session_for(user, %{"path" => "/notifications"})
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    refute has_element?(view, @bell_badge)
    # the messages badge is unaffected
    assert has_element?(view, @mail_badge, "1")
  end

  test "marking notifications read clears the notification badge", %{conn: conn} do
    user = with_unread_message(user_with_unread_notification())
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    send(view.pid, :notifications_read)

    refute has_element?(view, @bell_badge)
    # the messages badge is untouched
    assert has_element?(view, @mail_badge, "1")
  end
end
