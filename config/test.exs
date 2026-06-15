import Config

# Exercise the local upload-serving path (no nginx in tests either).
config :vutuv, :serve_uploads_locally, true

# Disable the fire-and-forget screenshot/gravatar tasks in tests: they would
# use the SQL Sandbox connection from a process that does not own it (crashing
# under async tests) and make a live HTTP request / launch headless Chromium.
config :vutuv, :generate_screenshots, false
config :vutuv, :fetch_gravatar, false
# Ads ship disabled (config/config.exs); the test suite exercises the full ad
# flow, so it runs with the system on. ads_disabled_test.exs flips it off.
config :vutuv, :ads_enabled, true
config :vutuv, :sweep_pending_images, false
config :vutuv, :sweep_unconfirmed_registrations, false
config :vutuv, :send_unread_message_emails, false
config :vutuv, :moderation_sweeper, false
config :vutuv, :prune_search_history, false
# Webhook deliveries run inline in tests (Vutuv.Webhooks.deliver_due/0 with a
# stubbed HTTP layer); the polling GenServer would touch the sandbox from
# outside. Vutuv.Webhooks.Deliverer.nudge/0 casts into the void then.
config :vutuv, :webhook_deliverer, false
# No headless Chromium in tests; the evidence capture is exercised manually.
config :vutuv, :capture_report_evidence, false
# Resolve every host to a fixed public IP so the SSRF fetch-time check
# (`Vutuv.Ssrf.resolves_to_internal?/1`) never hits real DNS in tests; the SSRF
# tests override this per-test to return an internal address.
config :vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
# Moderation emails deliver inline in tests: the async task would swallow the
# Swoosh test adapter's {:email, ...} message (it goes to the calling process).
config :vutuv, :async_email, false
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

# The bounce ingestion endpoint (POST /webhooks/bounces) is enabled with a
# fixed token in tests; production reads BOUNCE_WEBHOOK_TOKEN at runtime.
config :vutuv, :bounce_webhook_token, "test-bounce-webhook-token"
