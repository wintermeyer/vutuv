defmodule VutuvWeb.MessageLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  test "mounts and shows the seeded conversation", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, _view, html} = live(conn, ~p"/messages")

    assert html =~ "José Daniel"
    assert html =~ "Write a message"
  end

  test "redirects logged-out visitors to the login page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sessions/new"}}} = live(conn, ~p"/messages")
  end

  test "an unknown conversation id falls back to the default conversation", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, _view, html} = live(conn, ~p"/messages/999")

    # Conversation 1 is the fallback; its seeded message is shown.
    assert html =~ "Loved your Phoenix talk"
  end

  test "a message sent in one session appears live in another on the same conversation", %{
    conn: conn
  } do
    {conn, _user} = create_and_login_user(conn)

    {:ok, sender, _} = live(conn, ~p"/messages/1")
    {:ok, receiver, _} = live(conn, ~p"/messages/1")

    sender
    |> form("#message-form", message: %{body: "Real-time hello"})
    |> render_submit()

    # The broadcast to the other session is async; force it to be processed.
    _ = :sys.get_state(receiver.pid)

    assert render(receiver) =~ "Real-time hello"
  end

  test "typing in one session shows the animated typing bubble in another", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, typer, _} = live(conn, ~p"/messages/1")
    {:ok, watcher, _} = live(conn, ~p"/messages/1")

    typer
    |> form("#message-form", message: %{body: "typ"})
    |> render_change()

    _ = :sys.get_state(watcher.pid)

    assert has_element?(watcher, "#typing-bubble")
    assert render(watcher) =~ "is typing"
  end

  test "live messages get dom ids outside the seed id namespace", %{conn: conn} do
    # Regression: live ids came from System.unique_integer, which starts at 1 on
    # a fresh node — colliding with the seeded message's id 1, so the first sent
    # message silently REPLACED the seed row in the stream instead of appending.
    {conn, _user} = create_and_login_user(conn)

    {:ok, sender, _} = live(conn, ~p"/messages/1")

    sender
    |> form("#message-form", message: %{body: "No collision please"})
    |> render_submit()

    # The message comes back to the sender via PubSub; force it to be processed.
    _ = :sys.get_state(sender.pid)
    html = render(sender)

    assert html =~ ~s(id="message-live-)
    # the seeded message must still be there alongside the new one
    assert html =~ "Loved your Phoenix talk"
    assert html =~ "No collision please"
  end

  test "messages render markdown safely with a timestamp", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, sender, _} = live(conn, ~p"/messages/1")
    {:ok, receiver, _} = live(conn, ~p"/messages/1")

    sender
    |> form("#message-form",
      message: %{
        body:
          "**bold** <script>alert(1)</script> https://example.com/a/very/long/path/that/keeps/going/and/going"
      }
    )
    |> render_submit()

    _ = :sys.get_state(receiver.pid)
    html = render(receiver)

    assert html =~ "<strong>bold</strong>"
    refute html =~ "<script"
    # bare URL became a truncated link
    assert html =~ ~s(href="https://example.com/a/very/long/path/that/keeps/going/and/going")
    assert html =~ "…"
    # timestamp is rendered
    assert html =~ "<time"
  end
end
