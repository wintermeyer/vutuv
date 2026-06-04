defmodule VutuvWeb.ShellLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  @session %{"user_id" => 1, "user_name" => "Stefan Wintermeyer", "user_param" => "stefan"}

  test "renders the shell nav with dummy badges for a logged-in user", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, VutuvWeb.ShellLive, session: @session)

    assert html =~ "vutuv"
    assert has_element?(view, "#app-shell")
    # dummy seed: messages 2, notifications 3
    assert has_element?(view, "span.bg-accent", "2")
    assert has_element?(view, "span.bg-accent", "3")
  end

  test "shows a Log in button when logged out", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})
    assert has_element?(view, "a", "Log in")
    refute has_element?(view, "span.bg-accent")
  end

  test "a new-notification event bumps the bell badge", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: @session)

    send(view.pid, {:new_notification, %{text: "hi"}})

    assert has_element?(view, "span.bg-accent", "4")
  end

  test "the badge for the page being viewed starts at zero (no read-broadcast race)", %{
    conn: conn
  } do
    session = Map.put(@session, "path", "/notifications")
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    refute has_element?(view, "span.bg-accent", "3")
    # the messages badge is unaffected
    assert has_element?(view, "span.bg-accent", "2")
  end

  test "marking notifications read clears the notification badge", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: @session)

    send(view.pid, :notifications_read)

    refute has_element?(view, "span.bg-accent", "3")
    # the messages badge (2) is untouched
    assert has_element?(view, "span.bg-accent", "2")
  end
end
