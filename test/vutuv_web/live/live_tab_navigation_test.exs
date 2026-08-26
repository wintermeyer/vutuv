defmodule VutuvWeb.LiveTabNavigationTest do
  @moduledoc """
  Switching bottom tabs replaces the content, not the document (issue #1731).

  Two halves have to hold together, and each is worthless without the other.

  **The routing half.** `<.link navigate>` patches only *within one*
  `live_session`; across that boundary it degrades to a full navigation
  silently, which looks like it works. `/feed` was a controller route so it
  could negotiate its agent-format siblings, and a route that is not a `live`
  route cannot be in a live_session at all — so the tab members use most was
  the one tab that could never patch. It is a `live` route now, and its
  siblings are served from the pipeline instead.

  **The shell half.** The shell is embedded `sticky`, so a patch does not
  remount it and it has no `handle_params`: it has to be told where the reader
  ended up, or `@path` freezes at whatever page the document was built on and
  the wrong tab stays marked for the rest of the visit. That report is also
  what proves the browser can make it, which is why the links start as plain
  `href`s.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Sessions

  # `<.link navigate>` renders this beside the href; a plain link does not.
  @navigating ~s([data-phx-link="redirect"])

  # The shell authenticates the socket from the cookie's `session_token`, so a
  # test drives it with a real active session; `path` is the non-identity key
  # it reads straight from the mount session.
  defp shell_on(conn, user, path) do
    {token, _session} = Sessions.start_session(user, build_conn(), alert: false)
    session = %{"session_token" => token, "path" => path}

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session)

    view
  end

  # What the `ShellPath` hook sends: once when it mounts, then on every
  # `phx:navigate`.
  defp reports(view, path), do: render_hook(view, "shell:path", %{"path" => path})

  describe "the routing half" do
    # Driven from `ShellLive.live_paths/0`, not from a list repeated here: that
    # list is what decides whether a nav item gets `navigate`, and a path on it
    # that is not actually in the session degrades to a full page load with no
    # error anywhere. Asking the router about the shell's own list is what
    # makes that drift loud.
    test "every path the shell will patch to is in one live_session" do
      sessions =
        for path <- VutuvWeb.ShellLive.live_paths(), into: %{} do
          # `:get` explicitly — /search also has a POST route, and it is not
          # the one a tab press uses.
          route =
            Enum.find(
              VutuvWeb.Router.__routes__(),
              &(&1.path == path and &1.verb == :get)
            )

          case route && route.metadata[:phoenix_live_view] do
            {_view, _action, _opts, %{name: name}} -> {path, name}
            _ -> {path, :not_a_live_route}
          end
        end

      assert map_size(sessions) == 4, "the shell's list of patchable paths changed"

      assert Enum.uniq(Map.values(sessions)) == [:default],
             """
             Every path in `ShellLive.live_paths/0` has to be a `live` route in
             the SAME live_session, or `navigate` between them silently falls
             back to a full page load. Got: #{inspect(sessions)}.
             /feed was a controller route until #1731.
             """
    end

    test "the feed's agent-format siblings still answer at the same URL", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for {extension, content_type} <- [
            {".md", "text/markdown"},
            {".txt", "text/plain"},
            {".json", "application/json"},
            {".xml", "application/xml"}
          ] do
        response = get(recycle(conn), "/feed#{extension}")

        assert response.status == 200, "/feed#{extension} answered #{response.status}"

        assert response |> Plug.Conn.get_resp_header("content-type") |> hd() =~ content_type
      end
    end

    test "the HTML page still advertises them in its head", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/feed") |> html_response(200)

      for extension <- ~w(.md .txt .json .xml) do
        assert html =~ ~s(href="/feed#{extension}"),
               "the alternates moved with the negotiation; /feed#{extension} is unlisted"
      end
    end

    test "an unsupported extension is still a 404, never the HTML page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      response = get(conn, "/feed.vcf")

      assert response.status == 404
      refute response.resp_body =~ "<html"
    end
  end

  # The half no LiveView test can reach, so it is asserted at the source the
  # way the bundle-capability tests are.
  #
  # A full page load always started at the top; a patch does not. LiveView
  # stores the OUTGOING scroll position in the history entry (for a later Back)
  # and leaves the incoming page where the old one stood, with
  # `history.scrollRestoration` set to "manual" — measured in Chrome against
  # phoenix_live_view 1.1.30. Without the reset, pressing Messages from a
  # screen down the feed lands a screen down the messages page.
  test "a forward navigation starts the new page at the top" do
    app_js = File.read!("assets/js/app.js")

    assert app_js =~ "window.scrollTo(0, 0)",
           "the ShellPath hook has to put a patched-in page at the top itself"

    assert app_js =~ "if (!detail.patch && !detail.pop) window.scrollTo(0, 0)",
           """
           The reset must skip a `patch` (the same page changing its own URL —
           the notifications filter tabs and pager, where jumping to the top
           throws the reader's place away) and a `pop` (where LiveView is
           already restoring the position they left).
           """
  end

  describe "the shell half" do
    test "links are plain until the document says it can report back", %{conn: conn} do
      user = insert(:user)
      view = shell_on(conn, user, "/feed")

      # No hook has spoken yet: this is what an old bundle looks like for good.
      refute has_element?(view, ~s(nav a[href="/messages"]#{@navigating}))
      assert has_element?(view, ~s(nav a[href="/messages"]))

      reports(view, "/feed")
      assert has_element?(view, ~s(nav a[href="/messages"]#{@navigating}))
    end

    test "a destination outside the live_session stays a full load", %{conn: conn} do
      user = insert(:user, username: "stefan")
      view = shell_on(conn, user, "/feed")
      reports(view, "/feed")

      # The profile is still a controller route (five sibling formats), so
      # `navigate` there would degrade silently rather than patch.
      assert has_element?(view, ~s(a[data-mobile-profile]))
      refute has_element?(view, ~s(a[data-mobile-profile]#{@navigating}))
      refute has_element?(view, ~s(nav a[href="/jobs"]#{@navigating}))
    end

    test "and so does every link on a page that is itself outside it", %{conn: conn} do
      user = insert(:user, username: "stefan")
      view = shell_on(conn, user, "/stefan")
      reports(view, "/stefan")

      # A patch needs a live page to patch *from* as much as one to patch to.
      refute has_element?(view, ~s(nav a[href="/messages"]#{@navigating}))
      refute has_element?(view, ~s(nav a[href="/feed"]#{@navigating}))
    end

    test "the report moves the active tab with the reader", %{conn: conn} do
      user = insert(:user)
      view = shell_on(conn, user, "/feed")

      assert has_element?(view, ~s(nav a[href="/feed"][aria-current="page"]))

      reports(view, "/messages")

      assert has_element?(view, ~s(nav a[href="/messages"][aria-current="page"]))

      refute has_element?(view, ~s(nav a[href="/feed"][aria-current="page"])),
             """
             The shell is sticky, so nothing remounts it on a patch. If `@path`
             does not follow the reader, the tab they left stays marked for the
             rest of the visit.
             """
    end

    test "arriving at a list zeroes its badge without waiting for the broadcast", %{conn: conn} do
      user = insert(:user)
      insert(:follow, follower: insert(:user), followee: user)

      view = shell_on(conn, user, "/feed")
      assert has_element?(view, ~s(a[title="Notifications"] span.bg-accent), "1")

      reports(view, "/notifications")
      refute has_element?(view, ~s(a[title="Notifications"] span.bg-accent))
    end
  end
end
