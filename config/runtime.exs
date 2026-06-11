import Config

# Runtime configuration, read from the environment when the release boots.
# This is the only place production secrets enter the app, and nothing here
# is committed with a real value. On the server the values are supplied by a
# chmod-600 EnvironmentFile (/var/www/vutuv/shared/.env) loaded by systemd.
#
# Compile-time, non-secret prod settings live in config/prod.exs.

if config_env() == :prod do
  db_user = System.get_env("DB_USER") || "vutuv"
  db_name = System.get_env("DB_NAME") || "vutuv3_prod"
  db_host = System.get_env("DB_HOST") || "127.0.0.1"
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  db_pass =
    System.get_env("DB_PASS") ||
      raise """
      environment variable DB_PASS is missing.
      It must hold the PostgreSQL password for the #{db_name} database.
      """

  config :vutuv, Vutuv.Repo,
    username: db_user,
    password: db_pass,
    database: db_name,
    hostname: db_host,
    pool_size: pool_size

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "vutuv.de"
  port = String.to_integer(System.get_env("PORT") || "4003")

  config :vutuv, VutuvWeb.Endpoint,
    server: true,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    check_origin: ["https://#{host}", "https://www.vutuv.de"],
    public_url: "https://#{host}/"

  # Avatars and URL screenshots are written under this root and served by
  # nginx (location /avatars/, /screenshots/). Override with UPLOADS_DIR_PREFIX;
  # the default must match the nginx alias root or fresh uploads will 404.
  config :vutuv, :uploads_dir_prefix, System.get_env("UPLOADS_DIR_PREFIX") || "/srv/legacy-vutuv"

  # URL screenshots are rendered by local headless Chromium. Set CHROMIUM_PATH
  # if the binary is not on $PATH under one of the usual names.
  config :vutuv, :chromium_path, System.get_env("CHROMIUM_PATH")

  # Post images are auth-proxied: the app checks the post's audience, nginx
  # streams the bytes via X-Accel-Redirect from an `internal` location
  # (see README deploy notes). Dev/test use the send_file fallback instead.
  config :vutuv, :post_image_serving, :accel_redirect

  # Bearer token for POST /webhooks/bounces (the Postfix bounce pipe, see
  # README "Email bounce handling"). Unset => the endpoint 404s, bounce
  # handling is simply off; nothing else breaks.
  config :vutuv, :bounce_webhook_token, System.get_env("BOUNCE_WEBHOOK_TOKEN")
end
