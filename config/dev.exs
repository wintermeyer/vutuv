import Config

# No nginx locally: serve uploaded avatars/screenshots from the project dir.
config :vutuv, :serve_uploads_locally, true

config :vutuv, VutuvWeb.Endpoint,
  http: [port: 4000],
  url: [host: "localhost", port: 4000],
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
