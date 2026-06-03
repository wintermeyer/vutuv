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

  socket("/socket", VutuvWeb.UserSocket)

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :vutuv,
    gzip: false,
    only: ~w(assets css fonts images js favicon.ico)
  )

  # In production, avatars and screenshots are served directly by nginx from
  # config :vutuv, :uploads_dir_prefix. Locally there is no nginx, so optionally
  # serve them from the same directory the uploaders write to.
  if Application.compile_env(:vutuv, :serve_uploads_locally, false) do
    @uploads_root Application.compile_env(:vutuv, :uploads_dir_prefix, "")
    plug(Plug.Static, at: "/avatars", from: Path.join(@uploads_root, "avatars"), gzip: false)

    plug(Plug.Static,
      at: "/screenshots",
      from: Path.join(@uploads_root, "screenshots"),
      gzip: false
    )
  end

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session, @session_options)

  plug(VutuvWeb.Router)
end
