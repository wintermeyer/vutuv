import Config

# No nginx locally: serve uploaded avatars/screenshots from the project dir.
config :vutuv, :serve_uploads_locally, true

config :vutuv, VutuvWeb.Endpoint,
  http: [port: 4000],
  url: [host: "localhost", port: 4000],
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
    tailwind: {Tailwind, :install_and_run, [:vutuv, ~w(--watch)]}
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
  pool_size: 10

config :vutuv, Vutuv.Mailer, adapter: Swoosh.Adapters.Local

# Show a link to the Swoosh local mailbox (/sent_emails, forwarded only in dev)
# on the login pages so PINs are one click away while developing.
config :vutuv, :dev_mailbox, true
