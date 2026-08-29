defmodule VutuvWeb.ServiceWorkerController do
  @moduledoc """
  The two documents the installed web app needs that no other page can be
  (issue #1729): the service worker itself, and the one page it is allowed to
  keep.

  ## Why the worker is served from here rather than from `/assets`

  A worker controls the directory it is served from and everything under it, so
  a worker at `/assets/sw-<digest>.js` could control `/assets` and nothing
  else — no `push`, no `notificationclick` for the site. It has to sit at the
  root, which is also why it is not an esbuild entry point: `priv/static` is
  gitignored and built per deploy, while this file is read **at compile time**
  (`@external_resource`), so it is inside the release like any other beam and
  needs no asset step to exist.

  What is prepended to it as `self.VUTUV_SW_CONFIG` is what only the server
  knows:

    * the **asset version**, which is what the worker keys its cache on. It is
      the digested paths of the two tracked assets, so the bytes of this
      response change exactly when a browser holding the old bundle has become
      stale, and the previous release's cached assets are thrown away rather
      than accumulating. It does **not** raise the shell's "new version" bar:
      that reads the same two tracked assets, but per browser and from the
      server (`static_changed?/1`), because a worker waiting to take over says
      nothing about whether *this* document is the stale one. See
      `docs/architecture/realtime.md`.

    * the **generic notification lines**, one per kind per locale this
      installation serves. A push carries no content (see `Vutuv.WebPush`), so
      the worker draws the line itself, and a worker has no session and no
      gettext — it gets the table.

  `/system/offline` is under `/system/` and not at a root word for the usual
  reason (a root word is a handle nobody can claim afterwards); `sw.js` may sit
  at the root because a handle is `^[a-z0-9_]+$` and can never carry a dot,
  which is the same argument `/site.webmanifest` rides on.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.Endpoint
  alias VutuvWeb.PushLine

  @worker_path Path.expand("../../../assets/js/sw.js", __DIR__)
  @external_resource @worker_path
  @worker File.read!(@worker_path)

  # The tracked assets, exactly the two the root layout marks `phx-track-static`
  # — a browser is stale when either of them has moved on.
  @tracked ["/assets/app.css", "/assets/app.js"]

  @doc """
  The service worker.

  `no-cache` rather than a max-age: a browser re-checks a worker script on its
  own schedule (up to a day), and a member on an installed app is precisely the
  reader who reloads least.

  **The ETag is what makes that revalidation cheap, and it is not optional.**
  `no-cache` means "ask every time", not "do not store", so without a validator
  every check is a fresh 200 carrying the whole commented file — and Chrome
  runs an update check on navigation, which for an installed member is close to
  one full transfer per page. With it, the answer to an unchanged worker is an
  empty 304. The body is the validator's own input, so it also makes the
  version argument above observable to the browser's cache rather than merely
  true.
  """
  def script(conn, _params) do
    body = config_prelude() <> @worker
    etag = ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}")

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "no-cache")

    if fresh?(conn, etag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("text/javascript")
      |> send_resp(200, body)
    end
  end

  # `If-None-Match` is a comma-separated LIST, and a validator may come back
  # **weak** (`W/"…"`) — nginx marks an ETag weak when it compresses the body,
  # and a strict `==` against our one strong tag would then never match, so
  # every update check would fetch the whole file again and the 304 above would
  # be a promise nothing keeps. Compare the entity-tags, not the header.
  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == etag))
  end

  # The keys are spelled camelCase here rather than converted, because the file
  # that reads them is JavaScript and there are five of them.
  defp config_prelude do
    config = %{
      "version" => version(),
      "cacheAssets" => digested?(),
      "offlineUrl" => ~p"/system/offline",
      "icon" => ~p"/images/icon-192.png",
      "strings" => PushLine.table(),
      "fallbackLocale" => "en"
    }

    "self.VUTUV_SW_CONFIG = " <> Jason.encode!(config) <> ";\n"
  end

  defp version, do: Enum.map_join(@tracked, "|", &Endpoint.static_path/1)

  # Digests only exist where a cache manifest was built (prod). Without one,
  # `/assets/app.js` is one mutable URL and caching it first would serve a
  # stale bundle after every rebuild — so the worker does not cache in dev.
  defp digested? do
    is_binary(Application.get_env(:vutuv, Endpoint)[:cache_static_manifest])
  end

  @doc """
  The page the worker shows instead of the browser's own offline error.

  It is the one document this app stores, so everything that goes stale has to
  be absent from it: no CSRF token, no signed-in member, no `/assets`
  reference that a later deploy digests away. That is the **error layout's**
  problem too — a rescued 500 may not depend on the asset pipeline either — so
  this borrows that shell rather than inlining a second copy of the design
  system. Its only moving part is the language it was fetched in.
  """
  def offline(conn, _params) do
    conn
    |> put_root_layout(html: {VutuvWeb.LayoutHTML, :error})
    |> put_layout(html: false)
    |> put_resp_header("cache-control", "no-cache")
    |> render(:offline, page_title: gettext("No connection"))
  end
end
