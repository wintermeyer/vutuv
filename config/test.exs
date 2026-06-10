import Config

# Exercise the local upload-serving path (no nginx in tests either).
config :vutuv, :serve_uploads_locally, true

# Disable the fire-and-forget screenshot/gravatar tasks in tests: they would
# use the SQL Sandbox connection from a process that does not own it (crashing
# under async tests) and make a live HTTP request / launch headless Chromium.
config :vutuv, :generate_screenshots, false
config :vutuv, :fetch_gravatar, false
config :vutuv, :sweep_pending_images, false
config :vutuv, :sweep_unconfirmed_registrations, false
config :vutuv, :send_unread_message_emails, false
config :vutuv, :moderation_sweeper, false
config :vutuv, :reconcile_member_count, false

# Keep the Regenerator's stdout progress lines out of the test output.
config :vutuv, :regenerator_quiet, true

# Off by default so the suite's many logins do not share (and exhaust) one
# process-wide counter. The dedicated rate-limit test enables it explicitly.
config :vutuv, :rate_limit, enabled: false

config :vutuv, VutuvWeb.Endpoint,
  url: [host: "localhost", port: 4001],
  http: [port: 4001],
  server: false,
  public_url: "http://localhost:4000/",
  # Test-only signing key. Non-sensitive: the suite just needs a stable value
  # present so sessions / Phoenix.Token work. Production reads its own key from
  # SECRET_KEY_BASE in config/runtime.exs.
  secret_key_base: "+kJdlpOIQpuhsEHBa3bnyGjoAZMdkw7ig6N9J+pidN8pnjstub+viBVf9vSYFB8k"

config :logger, level: :warning

config :vutuv, Vutuv.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "postgres",
  database: "vutuv1_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  pool: Ecto.Adapters.SQL.Sandbox

config :vutuv, Vutuv.Mailer, adapter: Swoosh.Adapters.Test
