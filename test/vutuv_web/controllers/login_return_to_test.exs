defmodule VutuvWeb.LoginReturnToTest do
  use VutuvWeb.ConnCase, async: true

  # The developer docs link login-only pages (/access_tokens, /developers/apps)
  # that answer 404 to a logged-out reader on purpose, so the link goes through
  # /login?return_to=… instead: after the PIN the reader lands on the page the
  # docs meant, and a reader who is already signed in goes straight there.

  test "a logged-out reader lands on the linked page after the PIN", %{conn: conn} do
    conn = get(conn, "/login?return_to=/access_tokens")
    assert html_response(conn, 200)

    {:ok, _user} =
      Vutuv.Accounts.register_user(conn, %{
        "emails" => %{"0" => %{"value" => "docs-reader@example.com"}},
        "first_name" => "Docs",
        "tag_list" => @registration_tags
      })

    conn = post(conn, ~p"/login", session: %{"email" => "docs-reader@example.com"})
    conn = post(conn, ~p"/login", session: %{"pin" => sent_pin()})

    assert redirected_to(conn) == "/access_tokens"
  end

  test "a signed-in reader goes straight to the linked page", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get("/login?return_to=/developers/apps") |> redirected_to() ==
             "/developers/apps"
  end

  test "an address that leaves the site is ignored", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    assert conn |> get("/login?return_to=//evil.example/") |> redirected_to() ==
             VutuvWeb.Home.path(user)
  end
end
