defmodule VutuvWeb.Plug.PendingFlashTest do
  use VutuvWeb.ConnCase, async: true

  @moduledoc """
  A flash set on a response that is not a redirect is thrown away.

  `Phoenix.Controller.fetch_flash/2` persists the flash into the session only
  while `conn.status in 300..308`; on any other status its `before_send`
  callback *deletes* it. An action that answers **JSON** and lets the browser
  navigate afterwards — the passkey ceremonies, driven by `fetch()` — therefore
  loses whatever it flashed, with no error anywhere. That is why the passkey
  login's "Welcome back" greeting never appeared on screen.

  `put_pending_flash/3` + this plug carry the message to the next request
  instead, where an ordinary HTML response renders it.
  """

  alias VutuvWeb.Plug.PendingFlash

  # The member's next page load: same session, fresh request, the plug running
  # where the router puts it (right after fetch_flash).
  defp next_request(conn) do
    build_conn()
    |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
    |> Phoenix.Controller.fetch_flash()
    |> PendingFlash.call([])
  end

  describe "the problem it exists for" do
    test "Phoenix drops a flash set on a 200 JSON response", %{conn: conn} do
      # Pinning the platform behaviour this plug works around: if this ever
      # starts passing a flash through, the plug can go.
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> Phoenix.Controller.put_flash(:info, "carried?")
        |> Phoenix.Controller.json(%{ok: true})

      assert conn.status == 200
      refute get_session(conn, "phoenix_flash")
    end
  end

  describe "put_pending_flash/3 + the plug" do
    test "carries the message to the next request", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> PendingFlash.put_pending_flash(:info, "Welcome back, Ada!")
        |> Phoenix.Controller.json(%{ok: true})

      # Survives the JSON response, unlike a flash...
      assert get_session(conn, :pending_flash)

      # ...and lands in the flash of the very next page.
      next = next_request(conn)

      assert Phoenix.Flash.get(next.assigns.flash, :info) == "Welcome back, Ada!"
      # One-shot: it must not follow the member from page to page.
      refute get_session(next, :pending_flash)
    end

    test "keeps the kind, so an error does not arrive as good news", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> PendingFlash.put_pending_flash(:error, "That did not work.")
        |> Phoenix.Controller.json(%{ok: false})
        |> next_request()

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That did not work."
      refute Phoenix.Flash.get(conn.assigns.flash, :info)
    end

    test "does nothing when there is none pending", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> PendingFlash.call([])

      assert conn.assigns.flash == %{}
    end

    test "an already-flashed message on the same request is not clobbered", %{conn: conn} do
      # The plug runs on every browser request, including ones that set their own
      # flash later; it must only ever add.
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> PendingFlash.put_pending_flash(:info, "from the JSON step")
        |> next_request()
        |> Phoenix.Controller.put_flash(:error, "from this request")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "from the JSON step"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "from this request"
    end
  end

  describe "the passkey sign-in fallback (a real JSON action)" do
    test "the friendly note survives the JSON answer and shows on /login", %{conn: conn} do
      # Typing an address with no passkey mails a PIN and answers JSON telling
      # the JS where to go; the explanation has to reach the page it sends them
      # to (issue #834).
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "no-passkey@example.com", user: user)

      conn =
        post(conn, ~p"/login/passkey/challenge", %{"email" => "no-passkey@example.com"})

      assert %{"redirect" => "/login"} = json_response(conn, 200)

      html = conn |> recycle() |> get(~p"/login") |> html_response(200)
      assert html =~ "emailed you a one-time PIN"
    end
  end
end
