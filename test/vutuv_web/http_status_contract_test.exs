defmodule VutuvWeb.HttpStatusContractTest do
  @moduledoc """
  The application-wide HTTP status contract in one place: 200 only when
  the request actually succeeded, and the honest code otherwise —
  redirects for browser flows that need a login, 404 for pages that hide
  their existence, 403 for forbidden, 422 for failed validation, 429 over
  a rate limit. A page quietly answering 200 where it shouldn't is a
  regression this file catches.
  """

  use VutuvWeb.ConnCase

  describe "anonymous visitors" do
    test "public pages answer 200", %{conn: conn} do
      paths = [
        "/",
        "/login",
        "/community",
        "/developers",
        "/llms.txt",
        "/health",
        "/ads",
        "/robots.txt",
        "/sitemap.xml",
        "/posts/feed.xml",
        "/.well-known/agent-skills/index.json",
        "/.well-known/security.txt"
      ]

      for path <- paths do
        assert get(conn, path).status == 200, "expected 200 for #{path}"
      end
    end

    test "login-required browser pages redirect instead of rendering", %{conn: _conn} do
      # Classic controller pages bounce to the start page with a flash …
      for path <- ["/reports/new", "/ads/bookings", "/moderation/cases", "/admin"] do
        conn = get(build_conn(), path)
        assert conn.status == 302, "expected a redirect for #{path}, got #{conn.status}"
      end

      # … and the login-required LiveViews bounce to /login. /notifications
      # used to leak an empty 200 here.
      for path <- ["/feed", "/messages", "/notifications", "/likes", "/bookmarks"] do
        conn = get(build_conn(), path)
        assert conn.status == 302, "expected a redirect for #{path}, got #{conn.status}"
        assert redirected_to(conn) == "/login"
      end
    end

    test "pages that hide their existence answer 404", %{conn: conn} do
      for path <- ["/access_tokens", "/connected_apps", "/developers/apps", "/blocks"] do
        assert get(build_conn(), path).status == 404, "expected 404 for #{path}"
      end

      assert get(conn, "/no-such-member-xyz").status == 404
    end
  end

  describe "logged-in members" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "their pages answer 200", %{conn: conn} do
      for path <- ["/access_tokens", "/connected_apps", "/developers/apps", "/blocks"] do
        assert get(conn, path).status == 200, "expected 200 for #{path}"
      end
    end

    test "the admin panel answers 403 for non-admins", %{conn: conn} do
      assert get(conn, "/admin").status == 403
    end

    test "a failed form validation answers 422, not 200", %{conn: conn, user: _user} do
      # Through the shared save/3 chokepoint (an address without a value) …
      conn1 = post(conn, "/settings/phone_numbers", phone_number: %{"value" => ""})
      assert conn1.status == 422

      # … and through a hand-written error branch (a token without scopes).
      conn2 = post(conn, ~p"/access_tokens", token: %{"name" => "", "scopes" => []})
      assert conn2.status == 422
    end
  end

  describe "an Accept header no page can answer" do
    # `application/activity+json` rides the :browser pipeline's accepts list so
    # ActivityPub requests reach the profile and permalink controllers. Every
    # other page of that pipeline has no such representation, and a page whose
    # HTML is a LiveView used to answer one with a 500: no template for the
    # format, and `{:safe, iodata}` handed to `Plug.Conn.resp/3`. The honest
    # answer is the one `application/ld+json` has always given — 406.
    test "a LiveView page answers 406, exactly like it does for ld+json", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      # Both shapes: a controller that `live_render`s its page (/feed,
      # /organizations) and a routed LiveView (/notifications, /search,
      # /settings/tags/new).
      for path <- ["/feed", "/organizations", "/notifications", "/search", "/settings/tags/new"],
          type <- ["application/activity+json", "application/ld+json"] do
        conn = conn |> recycle() |> put_req_header("accept", type)

        assert_error_sent(406, fn -> get(conn, path) end)
      end
    end

    # The URL extension decides, not whatever header rode along with it: a
    # `.md` sibling is answered from `AgentDocs` by its controller and never
    # renders the LiveView, so the refusal must not reach it. `/:slug.md` is the
    # second path because it is the one where the two genuinely compete — the
    # bare `/:slug` answers an ActivityPub fetch, so before #1823 that branch
    # took the request and `enforce_handled/1` flipped it to an empty 404.
    test "an agent document is still served by its extension", %{conn: conn} do
      insert_activated_user(username: "extension_wins", first_name: "Agatha")

      for path <- ["/jobs.md", "/extension_wins.md"] do
        conn =
          conn
          |> recycle()
          |> put_req_header("accept", "application/activity+json")
          |> get(path)

        assert conn.status == 200, "expected 200 for #{path}"
        assert List.first(get_resp_header(conn, "content-type")) =~ "text/markdown"
      end
    end

    # Every routed LiveView, not a hand-picked five: the refusal is wired per
    # scope (`pipe_through`), so the next `live_session` scope that forgets
    # `:html_only` has to fail here rather than in production. Bare paths, so
    # this measures the pipeline; the extension siblings answer 404 by a
    # different route and are covered below.
    test "no routed LiveView answers a bare-path one with a 500", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      paths =
        for route <- VutuvWeb.Router.__routes__(),
            route.plug == Phoenix.LiveView.Plug,
            not String.contains?(route.path, ":"),
            do: route.path

      # Sanity: the sweep is only worth anything if it found the live routes.
      assert length(paths) > 20

      for path <- paths do
        conn = conn |> recycle() |> put_req_header("accept", "application/activity+json")

        assert_error_sent(406, fn -> get(conn, path) end)
      end
    end

    # The extension URL of a LiveView route that serves no agent document.
    # `AgentFormat` has already read the format off the URL, so the header the
    # client happened to send with it must not still steer the render: the
    # documented answer is `enforce_handled/1`'s 404, never a 500 from a
    # LiveView rendering for a format it has no template for.
    test "an extension URL on a LiveView route 404s whatever the client asked for", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for path <- ["/notifications.md", "/search.md", "/bookmarks.json"],
          type <- ["application/activity+json", "application/ld+json"] do
        conn = conn |> recycle() |> put_req_header("accept", type) |> get(path)

        assert conn.status == 404, "expected 404 for #{path} with #{type}"
      end
    end
  end

  describe "rate limits" do
    test "the login email step answers 429 over the limit", %{conn: conn} do
      previous = Application.get_env(:vutuv, :rate_limit)
      # An explicit small budget keeps the contract test decoupled from the
      # (deliberately generous) production default of 50 per 3h.
      Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 3, window_ms: 60_000)
      Vutuv.RateLimiter.reset()
      on_exit(fn -> Application.put_env(:vutuv, :rate_limit, previous) end)

      last =
        Enum.reduce(1..4, conn, fn _n, _acc ->
          post(build_conn(), ~p"/login", session: %{"email" => "rate@example.com"})
        end)

      assert last.status == 429
    end
  end

  describe "no account-enumeration tell at the PIN step" do
    setup do
      Vutuv.RateLimiter.reset()
      :ok
    end

    test "wrong PINs for a known and an unknown address lock out identically", %{conn: conn} do
      user = insert_activated_user()
      insert(:email, user: user, value: "real@example.com")

      known = wrong_pin_until_lockout(conn, "real@example.com")
      unknown = wrong_pin_until_lockout(conn, "ghost@example.com")

      # The lockout arrives on the same attempt, with the same status, the
      # same redirect target and the same flash — nothing distinguishes the
      # real address from the made-up one.
      assert known == unknown
      assert {3, 302, "/login"} = known
    end

    # Drive step 1 (email) then submit wrong PINs until the response stops
    # being the "incorrect PIN" redirect-to-"/" and becomes the lockout
    # redirect-to-"/login". Returns {attempt_number, status, location}.
    defp wrong_pin_until_lockout(conn, email) do
      {:ok, conn} = Vutuv.Accounts.login_by_email(conn, email, :login)

      Enum.reduce_while(1..5, conn, fn n, acc ->
        acc = post(acc, ~p"/login", session: %{"pin" => "000000"})
        location = redirected_to(acc)

        if location == "/login" do
          {:halt, {n, acc.status, location}}
        else
          {:cont, acc}
        end
      end)
    end
  end
end
