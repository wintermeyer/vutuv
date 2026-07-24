defmodule VutuvWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vutuv, adapter: Bandit.PhoenixAdapter

  # Shared by `Plug.Session` (dead HTTP requests) and the LiveView socket below,
  # so a logged-in session is readable over the websocket. Keep `key` and
  # `signing_salt` identical to what lived inline on `Plug.Session` before,
  # otherwise existing session cookies stop decoding and everyone is logged out.
  @session_options [
    store: :cookie,
    key: "_vutuv_key",
    signing_salt: "UOTk6kQ0",
    max_age: 7_776_000
  ]

  # Cap a single websocket frame so no client can push an arbitrarily large
  # payload over the LiveView socket (Phoenix's default is "infinity"). 1 MB
  # clears every legitimate flow — LiveView uploads chunk at 64 kB, and the
  # largest composer draft (a 20,000-character post body, worst case ~80 kB of
  # UTF-8) rides well under it — while bounding a hostile frame. Only a single
  # frame above 1 MB (an oversized paste far past the 20,000-char post limit, or
  # a malicious payload) now closes the connection to reconnect.
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 1_000_000]
  )

  # In dev, serve static assets with `cache-control: no-cache` so the browser
  # always revalidates against the ETag after a Tailwind rebuild (a 304 when the
  # file is unchanged, a fresh 200 when it changed) instead of heuristically
  # reusing a stale `app.css`. The Plug.Static default (`"public"` with an ETag
  # and Last-Modified but no freshness directive) lets browsers serve a cached
  # stylesheet for a heuristic window without asking the server, which shipped a
  # blank (gradient-less) landing-page hero until a hard reload.
  #
  # Prod is untouched: `"public"` is exactly the Plug.Static default, and prod's
  # digested assets are referenced with `?vsn=` and served via
  # `:cache_control_for_vsn_requests` (the long immutable cache), which this
  # option does not affect.
  @static_etag_cache_control if Mix.env() == :dev, do: "no-cache", else: "public"

  plug(Plug.Static,
    at: "/",
    from: :vutuv,
    gzip: false,
    only: ~w(assets css fonts images js favicon.ico),
    cache_control_for_etags: @static_etag_cache_control
  )

  # In production, avatars/covers/screenshots are served directly by nginx from
  # config :vutuv, :uploads_dir_prefix. Locally there is no nginx, so optionally
  # serve them from the same directory the uploaders write to.
  #
  # The `originals/` subtree (Vutuv.Uploads.Originals) holds every uploaded
  # original and is deliberately NOT mounted — neither here nor as an nginx
  # alias. Nobody may download a full-resolution original (with its EXIF/GPS
  # data); see test/vutuv_web/uploads_serving_test.exs.
  if Application.compile_env(:vutuv, :serve_uploads_locally, false) do
    @uploads_root Application.compile_env(:vutuv, :uploads_dir_prefix, "")
    plug(Plug.Static, at: "/avatars", from: Path.join(@uploads_root, "avatars"), gzip: false)
    plug(Plug.Static, at: "/covers", from: Path.join(@uploads_root, "covers"), gzip: false)

    plug(Plug.Static,
      at: "/screenshots",
      from: Path.join(@uploads_root, "screenshots"),
      gzip: false
    )
  end

  # Tidewave (dev-only dep) exposes an MCP endpoint at /tidewave/mcp so AI
  # coding agents can inspect the running app (eval code, query Ecto, read
  # logs). The guard keeps the plug out of test and prod builds.
  if Code.ensure_loaded?(Tidewave) do
    plug(Tidewave)
  end

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  # In production nginx terminates TLS and proxies to us over loopback, so the
  # TCP peer is always 127.0.0.1. RemoteIp rewrites `conn.remote_ip` from the
  # `X-Forwarded-For` header nginx sets; it trusts the reserved/loopback proxy
  # hop by default and takes the closest non-proxy address, so a client cannot
  # spoof it. Every downstream reader (the session fingerprint behind the
  # security email, the per-IP rate limiter) then sees the real visitor address
  # instead of a single shared loopback bucket (issues #799, #837). A no-op in
  # dev/test, where there is no proxy and no forwarded header.
  plug(RemoteIp)

  plug(Plug.RequestId)
  plug(Plug.Logger)

  # The multipart cap must sit above the LinkedIn import's 50 MB limit
  # (ImportController), or its friendly too-large flash can never fire — the
  # default 8 MB rejected the very archives the import page asks members to
  # download. Beyond 64 MB Plug raises and the member gets the styled 413 page
  # (VutuvWeb.ErrorHTML). nginx's client_max_body_size must stay >= this.
  # body_reader: the ActivityPub inbox verifies an HTTP signature over the
  # raw body bytes, which the JSON parser (application/activity+json is a
  # +json type) would otherwise consume — VutuvWeb.RawBodyReader keeps a copy
  # for exactly that one path.
  plug(Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: 64_000_000}, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {VutuvWeb.RawBodyReader, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  # After Plug.Head (HEAD arrives here as GET), before the router: strips the
  # agent-document extensions (.md/.txt/.json/.vcf) off the path so
  # /stefan.wintermeyer.md matches the /:slug route; see VutuvWeb.AgentDocs.
  plug(VutuvWeb.Plug.AgentFormat)

  # The login-session cookie (`_vutuv_key`, which carries the `session_token`
  # `VutuvWeb.Plug.ConfigureSession` trusts) must be marked `Secure` +
  # `SameSite=Lax` over https, so an on-path attacker on a plain-HTTP request can
  # never observe or replay it. But whether the cookie may be `Secure` depends on
  # the endpoint's PUBLIC scheme, which is set at RUNTIME (config/runtime.exs):
  # https on the internet, http on an intranet install and in dev/test. An
  # unconditional `secure: true` would make the cookie unusable over plain HTTP.
  # `@session_options` is a compile-time attribute, so the scheme-dependent flags
  # are added per request here; the LiveView socket above keeps the plain
  # `@session_options` (it only DECODES the cookie, so `secure`/`same_site` are
  # irrelevant there — and must not change, or the key/signing_salt drift and
  # everyone is logged out).
  plug(:secure_session)

  plug(VutuvWeb.Router)

  @doc """
  The operator's public base URL (endpoint config `:public_url`). Used to build
  the absolute unsubscribe / alert-off links the token modules mint outside a
  request, where `url/0` is not available.
  """
  def public_url, do: config(:public_url)

  @doc """
  Whether cookies this endpoint sets may carry the `Secure` flag: true only when
  the public scheme is https. False on a plain-HTTP (intranet) install and in
  dev/test, where a `Secure` cookie would never be sent back over http and would
  break login. Read here by `Plug.Session` and by the login-identity PIN cookie
  in `Vutuv.Accounts.put_pin_cookie/2`.
  """
  def secure_cookies?, do: config(:url)[:scheme] == "https"

  # The `Plug.Session` options with the scheme-dependent `secure` flag and
  # `SameSite=Lax` added onto the compile-time `@session_options`. Its
  # `key`/`signing_salt`/`max_age` are `@session_options` unchanged, so existing
  # cookies keep decoding. Public (`@doc false`) as a test seam: the session
  # test builds it for an https and an http scheme without mutating global config.
  @doc false
  def session_options(secure?) do
    @session_options ++ [secure: secure?, same_site: "Lax"]
  end

  defp secure_session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options(secure_cookies?())))
  end
end
