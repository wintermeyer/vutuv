defmodule VutuvWeb.SessionCookieTest do
  @moduledoc """
  The login-session cookie (`_vutuv_key`, which carries the `session_token`
  `VutuvWeb.Plug.ConfigureSession` trusts) and the login-identity PIN cookie
  (`_vutuv_login_pin`) must be marked `Secure` + `SameSite=Lax` over https, so an
  on-path attacker on a plain-HTTP request can neither observe nor replay them —
  while staying usable over plain http on an intranet install (and in dev/test),
  where a `Secure` cookie would never be sent back and would break login.

  `async: false`: the https cases temporarily override the shared, ETS-backed
  `VutuvWeb.Endpoint` `:url` scheme (process/node-global config every generated
  URL reads). ExUnit runs sync modules only after all async modules finish, and
  runs them serially, so no other module can observe the override; each case
  restores the original `:url` in an `after` regardless of outcome.
  """
  use VutuvWeb.ConnCase, async: false

  alias Plug.Conn
  alias Vutuv.Accounts
  alias VutuvWeb.Endpoint

  @session_cookie "_vutuv_key"
  @pin_cookie "_vutuv_login_pin"

  # Run `fun` with the endpoint's public URL scheme forced to `scheme`, then
  # restore the original `:url` config. `Endpoint.config/1` reads
  # `:ets.lookup(Endpoint, :url)` directly, so overwriting just that one key is
  # the minimal, self-contained way to flip the scheme the cookie gate reads.
  defp with_scheme(scheme, fun) do
    original = Endpoint.config(:url)

    try do
      :ets.insert(Endpoint, {:url, Keyword.put(original, :scheme, scheme)})
      fun.()
    after
      :ets.insert(Endpoint, {:url, original})
    end
  end

  # The `set-cookie` header string a browser would actually receive for `name`.
  defp set_cookie(conn, name) do
    conn
    |> Conn.get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, name <> "="))
  end

  describe "Endpoint.secure_cookies?/0 gate" do
    test "is false when the public scheme is http (the default test env)" do
      refute Endpoint.secure_cookies?()
    end

    test "is true only when the public scheme is https" do
      with_scheme("https", fn -> assert Endpoint.secure_cookies?() end)
    end
  end

  describe "session_options/1 builder" do
    test "adds Secure + SameSite=Lax over https, keeping key/signing_salt/max_age" do
      opts = Endpoint.session_options(true)

      assert opts[:secure] == true
      assert opts[:same_site] == "Lax"
      # The cookie identity must not drift, or every existing session is logged out.
      assert opts[:key] == "_vutuv_key"
      assert opts[:signing_salt] == "UOTk6kQ0"
      assert opts[:max_age] == 7_776_000
    end

    test "leaves Secure off over http so a plain-HTTP install still works" do
      opts = Endpoint.session_options(false)

      assert opts[:secure] == false
      assert opts[:same_site] == "Lax"
    end
  end

  describe "the session cookie (_vutuv_key) on a real request" do
    test "is HttpOnly + SameSite=Lax and NOT Secure over http (login works over http)" do
      # The Locale plug writes the session on every browser request, so the
      # landing page emits a fresh session cookie we can inspect.
      conn = get(build_conn(), "/")
      cookie = set_cookie(conn, @session_cookie)

      assert cookie, "expected the session write to set #{@session_cookie}"
      assert cookie =~ "; SameSite=Lax"
      assert cookie =~ "; HttpOnly"
      refute cookie =~ "; secure"
    end

    test "is Secure + SameSite=Lax + HttpOnly when the public scheme is https" do
      with_scheme("https", fn ->
        conn = get(build_conn(), "/")
        cookie = set_cookie(conn, @session_cookie)

        assert cookie =~ "; secure"
        assert cookie =~ "; SameSite=Lax"
        assert cookie =~ "; HttpOnly"
      end)
    end
  end

  describe "the login-identity PIN cookie (_vutuv_login_pin)" do
    test "is HttpOnly + SameSite=Lax and NOT Secure over http", %{conn: conn} do
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "pin-http@example.com", user: user)

      {:ok, returned} = Accounts.login_by_email(conn, "pin-http@example.com")
      cookie = returned |> Conn.send_resp(200, "") |> set_cookie(@pin_cookie)

      assert cookie
      assert cookie =~ "; HttpOnly"
      assert cookie =~ "; SameSite=Lax"
      refute cookie =~ "; secure"
    end

    test "is Secure (still HttpOnly + SameSite=Lax) when the public scheme is https", %{
      conn: conn
    } do
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "pin-https@example.com", user: user)

      with_scheme("https", fn ->
        {:ok, returned} = Accounts.login_by_email(conn, "pin-https@example.com")
        cookie = returned |> Conn.send_resp(200, "") |> set_cookie(@pin_cookie)

        assert cookie =~ "; secure"
        assert cookie =~ "; SameSite=Lax"
        assert cookie =~ "; HttpOnly"
      end)
    end
  end
end
