defmodule VutuvWeb.ShellLiveUpdateBarTest do
  @moduledoc """
  The "a new version is ready" bar (issue #1729).

  What it is really about is **who gets asked to reload**. A deploy reloads
  nothing: an open page keeps the bundle it downloaded, and an installed app is
  reloaded rarer still. But a page loaded *after* the deploy is already on the
  new release — its HTML came from the server and its digested assets came with
  it — so offering that reader a reload is asking them to fix what is not
  broken.

  The service worker cannot tell those two apart. `registration.waiting` stays
  set until every vutuv tab is gone, so it was still true on a document that had
  just arrived from the new release, and the bar came back on every page load
  until somebody pressed it. The server can tell them apart, because
  `phx-track-static` reports the bundle this browser is actually running.

  Not `async`: the stale branch needs the endpoint to claim a digest manifest,
  and that is global.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # A manifest the tracked assets below either match or miss on purpose.
  @manifest %{"assets/app.js" => "assets/app-CURRENT.js"}
  @current ["http://localhost/assets/app-CURRENT.js"]
  @stale ["http://localhost/assets/app-PREVIOUS.js"]

  setup do
    Vutuv.EndpointHostHelper.with_endpoint_config(:cache_static_manifest_latest, @manifest)
  end

  defp mount_shell(conn, connect_params, session \\ %{}) do
    {:ok, _view, html} =
      conn
      |> put_connect_params(connect_params)
      |> live_isolated(VutuvWeb.ShellLive, session: session)

    html
  end

  describe "who gets offered the reload" do
    test "a browser still running the previous release is offered it", %{conn: conn} do
      html = mount_shell(conn, %{"_track_static" => @stale})

      assert html =~ ~s(id="sw-update")
      assert html =~ "A new version is ready."
    end

    # Reload must be a LINK, not a button. This bar is only ever rendered into a
    # document running the previous release's JavaScript, and that handler does
    # nothing at all when no worker happens to be waiting — which is the usual
    # case for a tab that has been open across the deploy. The href is what
    # still carries the reader to the new release (and what makes the control
    # work with JavaScript off), so a refactor to `<button>` is a regression.
    test "the reload control is a link to the page itself", %{conn: conn} do
      html = mount_shell(conn, %{"_track_static" => @stale})

      assert [reload] =
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query("[data-sw-reload]")
               |> Enum.to_list()

      assert LazyHTML.tag(reload) == ["a"]
      assert LazyHTML.attribute(reload, "href") == ["/"]
    end

    # The regression this file exists for. Before the gate the bar was in every
    # document, and the service worker unhid it whenever a worker was waiting —
    # which it still is on a page that arrived fresh from the new release.
    test "a browser already running the current release is not", %{conn: conn} do
      html = mount_shell(conn, %{"_track_static" => @current})

      refute html =~ ~s(id="sw-update")
    end

    # A browser that reports no bundle (a page that lost the `phx-track-static`
    # annotation) gives the gate nothing to judge by, and it must then stay
    # quiet rather than guess — which is the whole complaint being fixed.
    test "a browser that reports no bundle at all is not", %{conn: conn} do
      html = mount_shell(conn, %{})

      refute html =~ ~s(id="sw-update")
    end
  end

  # The shape that actually broke, and the reason this describe exists rather
  # than the `live_isolated/3` cases above being thought sufficient. Those mount
  # the shell as a ROOT LiveView, which is what it is on a classic controller
  # page. But `app.html.heex` embeds it with `live_render`, so a LiveView page's
  # first HTTP paint takes `Static.disconnected_nested_render/6` — which sets
  # `conn_session` and **no** `connect_params`, and `static_changed?/1` raises
  # there rather than answering false. Calling it without the `connected?/1`
  # short-circuit 500s every one of these pages, and the raise's own message
  # ("store the state in socket assigns") points nowhere near the cause.
  describe "the disconnected render of a page embedding the shell" do
    test "a classic controller page still paints", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200)
    end

    test "a LiveView page still paints", %{conn: conn} do
      assert conn |> get(~p"/search") |> html_response(200)
    end
  end

  # The bar used to carry a "Later" beside the reload, and it should not come
  # back — the reasoning is in `docs/architecture/realtime.md`. What this pins
  # is the count: one control in the bar, and it is the reload. The selector
  # names `[phx-click]` as well as the two control tags, because the shape to
  # catch is a dismiss wired to any element at all, not one spelled `<button>`.
  describe "there is no way to put it away" do
    test "the reload is the only control in the bar", %{conn: conn} do
      html = mount_shell(conn, %{"_track_static" => @stale})

      assert [reload] =
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query(~s(#sw-update a, #sw-update button, #sw-update [phx-click]))
               |> Enum.to_list()

      assert LazyHTML.attribute(reload, "data-sw-reload") == [""]
    end
  end

  # Both translated locales, by name. A short msgid is exactly what
  # `gettext.extract --merge` fuzzy-fills from an unrelated string, and it did
  # to the "Later" this bar used to carry: German came back as "Letzter Fehler"
  # (last error) and Italian as "Ultimo errore". Nothing failed the build, and
  # English stayed green — so the only thing standing between that and a shipped
  # button labelled "last error" is an assertion naming the words.
  for {locale, expected} <- [
        {"de", ["Neue Version bereit.", "Neu laden"]},
        {"it", ["È pronta una nuova versione.", "Ricarica"]}
      ] do
    test "the #{locale} render says both lines in #{locale}", %{conn: conn} do
      html =
        mount_shell(conn, %{"_track_static" => @stale}, %{"locale" => unquote(locale)})

      for line <- unquote(expected), do: assert(html =~ line)
    end
  end
end
