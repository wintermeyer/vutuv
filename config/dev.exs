import Config

# No nginx locally: serve uploaded avatars/screenshots from the project dir.
config :vutuv, :serve_uploads_locally, true

# AI image scans in dev: try bremen3's GPU Ollama first through the local
# WireGuard tunnel (10.28.0.3 — answers in seconds), fall back to the Mac's
# own Ollama when the tunnel is down. Same priority-list mechanism prod uses;
# without either instance running, uploads simply wait in limbo (fail-closed),
# so dev keeps working — the pill just stays until a scan answers.
config :vutuv, :ollama_url, "http://10.28.0.3:11434,http://localhost:11434"

# Relax the dev Content-Security-Policy to allow `'unsafe-eval'` for scripts so
# Tidewave's `browser_eval` tool (which runs page JS via eval, e.g. to measure
# layout and confirm a change isn't clipped) is not blocked. DEV ONLY — the flag
# is read with compile_env and is never set in prod/test. Remove this line (or
# set it to false) to restore the strict `default-src 'self'` policy. See the
# long note in VutuvWeb.Plug.ContentSecurityPolicy.
config :vutuv, csp: [allow_eval: true]

config :vutuv, VutuvWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")],
  url: [host: "localhost", port: String.to_integer(System.get_env("PORT") || "4000")],
  # Dev-only signing secret so `mix phx.server` boots without extra setup.
  # This is not a real secret: it only signs localhost dev sessions/cookies.
  # Production reads its secret_key_base from the environment in runtime.exs,
  # and the test env has its own in config/test.exs.
  secret_key_base: "ijWzKCx7VABaOUeORdkVKPKRD3oDmIkgeynooZRJ64AvDyMpbY3dAPZmU2LlegOv",
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:vutuv, ~w(--sourcemap=inline --watch)]},
    # Not `tailwind --watch`: the v4 CLI's watch mode rebuilds from a cached
    # copy of @import'ed CSS and ignores CSS edits outright, so changes to
    # components.css silently never reached the browser. The replacement runs
    # a correct one-shot build per change — see VutuvWeb.TailwindWatcher.
    tailwind: {VutuvWeb.TailwindWatcher, :watch, [:vutuv]}
  ],
  public_url: "http://localhost:4000/",
  live_reload: [
    patterns: [
      ~r{priv/static/(?!assets).*\.(js|css|png|jpeg|jpg|gif|svg)$},
      ~r{priv/static/assets/.*(js|css)$},
      ~r{priv/gettext/.*(po)$},
      ~r{lib/vutuv_web/views/.*(ex)$},
      ~r{lib/vutuv_web/templates/.*(eex|heex)$}
    ]
  ]

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :vutuv, Vutuv.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "postgres",
  database: "vutuv1_dev",
  hostname: "localhost",
  pool_size: 10,
  # Keep the dev log readable: don't echo every SQL query.
  log: false

config :vutuv, Vutuv.Mailer, adapter: Swoosh.Adapters.Local

# Show a link to the Swoosh local mailbox (/sent_emails, forwarded only in dev)
# on the login pages so PINs are one click away while developing.
config :vutuv, :dev_mailbox, true

# Exercise the bounce webhook locally:
#   curl -X POST -H "Authorization: Bearer dev-bounce-webhook-token" \
#     -H "Content-Type: message/rfc822" --data-binary @dsn.eml \
#     http://localhost:4000/webhooks/bounces
config :vutuv, :bounce_webhook_token, "dev-bounce-webhook-token"

# No Postfix mail log to tail in dev; the log watcher stays off (it would also
# start with no configured path and just :ignore). Test bounce handling via the
# webhook above, or the Deliverability context directly.
config :vutuv, :bounce_watcher, false
