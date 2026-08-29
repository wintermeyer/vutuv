defmodule VutuvWeb.ServiceWorkerTest do
  @moduledoc """
  The two documents the installed web app needs (issue #1729): `/sw.js` and the
  offline page it keeps.

  `async: false` because the `/sw.js` group flips `:web_push_enabled`, which is
  global and read by every push path in the app.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers

  alias Vutuv.WebPush

  describe "GET /sw.js" do
    test "is served from the root, as JavaScript a worker may install", %{conn: conn} do
      conn = get(conn, "/sw.js")

      assert response(conn, 200)
      assert ["text/javascript" <> _] = get_resp_header(conn, "content-type")
      # A browser re-checks a worker script on its own schedule (up to a day),
      # and an installed app is what reloads least — so it must revalidate.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    # The whole design of this worker. A cached page carries a stale CSRF token
    # and whoever was signed in when it was stored, and the LiveView socket
    # would join against a document the server never sent. If somebody ever
    # widens the cache rule, this is what says no.
    test "caches assets and the offline page, and nothing else", %{conn: conn} do
      body = conn |> get("/sw.js") |> response(200)

      assert body =~ ~s|pathname.startsWith("/assets/")|
      assert body =~ "offlineUrl"
      # A navigation goes to the network and is never put in the cache; the
      # only `cache.put` in the file is the asset branch.
      assert length(String.split(body, "cache.put")) == 2
    end

    # `no-cache` means "ask every time", not "do not store" — so without a
    # validator every one of those asks is a fresh 200 carrying the whole
    # commented file, and Chrome asks on navigation.
    test "answers an unchanged worker with an empty 304", %{conn: conn} do
      first = get(conn, "/sw.js")
      assert [etag] = get_resp_header(first, "etag")

      second = build_conn() |> put_req_header("if-none-match", etag) |> get("/sw.js")

      assert response(second, 304) == ""
    end

    # A proxy that transforms the body marks the validator weak, and
    # `If-None-Match` is a list either way — a strict comparison would answer
    # 200 for ever and the revalidation would cost the whole file every time.
    test "recognises a weak or listed validator too", %{conn: conn} do
      assert [etag] = conn |> get("/sw.js") |> get_resp_header("etag")

      weak = build_conn() |> put_req_header("if-none-match", "W/" <> etag) |> get("/sw.js")

      listed =
        build_conn() |> put_req_header("if-none-match", ~s("stale", ) <> etag) |> get("/sw.js")

      stale = build_conn() |> put_req_header("if-none-match", ~s("stale")) |> get("/sw.js")

      assert response(weak, 304) == ""
      assert response(listed, 304) == ""
      assert stale.status == 200
    end

    test "carries the generic push lines for every locale this installation serves", %{conn: conn} do
      body = conn |> get("/sw.js") |> response(200)

      assert %{"strings" => strings} = config(body)

      for locale <- Vutuv.Languages.site_locales(),
          kind <- ~w(message follower activity) do
        assert is_binary(strings[kind][locale]),
               "no #{kind} line for #{locale}"
      end
    end

    # A push carries no content, so what a lock screen shows is drawn from
    # these strings alone — and a line that named the sender or quoted the text
    # would put it there.
    test "the German line names the kind and nothing else", %{conn: conn} do
      body = conn |> get("/sw.js") |> response(200)

      assert config(body)["strings"]["message"]["de"] == "Neue Nachricht auf vutuv"
    end

    test "does not cache assets where they are served undigested", %{conn: conn} do
      # Dev and test serve `/assets/app.js` at one mutable URL, so a cache-first
      # rule would hand back yesterday's bundle after a rebuild.
      assert config(conn |> get("/sw.js") |> response(200))["cacheAssets"] == false
    end

    # The bytes of this response are what a browser compares to decide there is
    # a new worker, and that is what raises the "new version" bar. Keyed on the
    # digested asset paths, so it moves exactly when an open page has gone
    # stale — not on every deploy, and not never.
    test "the cache version follows the tracked assets", %{conn: conn} do
      version = config(conn |> get("/sw.js") |> response(200))["version"]

      assert version =~ "/assets/app.css"
      assert version =~ "/assets/app.js"
    end
  end

  describe "GET /system/offline" do
    test "renders a whole document with no session in it", %{conn: conn} do
      body = conn |> get(~p"/system/offline") |> html_response(200)

      assert body =~ "<!doctype html>"
      # It borrows the error layout, which solves the same problem for the
      # rescued-500 path: one self-contained document, styling inlined.
      assert body =~ "error-page"
      assert body =~ "<style>"
      # The one page this app stores. A CSRF token in it would be handed to a
      # form days later, and an /assets reference would point at a digest a
      # deploy has since removed.
      refute body =~ "csrf-token"
      refute body =~ "/assets/"
    end

    test "speaks the reader's language", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/system/offline")
        |> html_response(200)

      assert body =~ "Keine Verbindung"
      assert body =~ ~s|lang="de"|
    end
  end

  describe "an installation with push switched off" do
    setup do
      put_config(:web_push_enabled, false)
      :ok
    end

    # The worker is not only about push: the offline page and the asset cache
    # are worth having on an intranet installation too. What must be gone is
    # the key, and with it the switch that would ask a browser to subscribe.
    test "still serves the worker", %{conn: conn} do
      assert conn |> get("/sw.js") |> response(200)
      refute WebPush.public_key()
    end
  end

  defp config(body) do
    [_before, json] = String.split(body, "self.VUTUV_SW_CONFIG = ", parts: 2)
    [json, _rest] = String.split(json, ";\n", parts: 2)
    Jason.decode!(json)
  end
end
