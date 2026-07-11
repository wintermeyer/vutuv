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

  # The public scheme. https is the right answer on the internet; an intranet
  # installation without TLS sets PHX_SCHEME=http (and usually PHX_URL_PORT).
  scheme = System.get_env("PHX_SCHEME") || "https"

  default_url_port = if scheme == "https", do: "443", else: "80"
  url_port = String.to_integer(System.get_env("PHX_URL_PORT") || default_url_port)

  # Allowed websocket origins: the canonical host plus its www. sibling (a
  # tolerated alias that redirects; the canonical domain carries no www).
  # CHECK_ORIGINS appends extra origins, comma-separated, for installations
  # served under more than one name.
  extra_origins =
    "CHECK_ORIGINS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  url_authority = if url_port in [80, 443], do: host, else: "#{host}:#{url_port}"

  config :vutuv, VutuvWeb.Endpoint,
    server: true,
    url: [host: host, port: url_port, scheme: scheme],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    check_origin:
      ["#{scheme}://#{url_authority}", "#{scheme}://www.#{url_authority}"] ++ extra_origins,
    public_url: "#{scheme}://#{url_authority}/"

  # Outbound SMTP. The defaults deliver in plaintext to a local relay on the
  # loopback (the vutuv.de production setup: Postfix on the same host).
  # STARTTLS to 127.0.0.1 fails the handshake there ("wrong version number")
  # and silently drops the mail; TLS on loopback adds nothing, and Postfix
  # still uses TLS for its onward hops to the real MX. An installation using
  # a remote smarthost sets SMTP_RELAY/SMTP_PORT/SMTP_USERNAME/SMTP_PASSWORD
  # and SMTP_TLS=always (STARTTLS) or SMTP_SSL=true (implicit TLS, port 465).
  smtp_tls =
    case System.get_env("SMTP_TLS", "never") do
      "always" -> :always
      "if_available" -> :if_available
      _never -> :never
    end

  config :vutuv, Vutuv.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SMTP_RELAY") || "127.0.0.1",
    port: String.to_integer(System.get_env("SMTP_PORT") || "25"),
    username: System.get_env("SMTP_USERNAME") || "",
    password: System.get_env("SMTP_PASSWORD") || "",
    tls: smtp_tls,
    ssl: System.get_env("SMTP_SSL") == "true",
    retries: 3

  # Operator identity overrides (defaults in config/config.exs are the
  # vutuv.de values; see the "Operator identity" block there).
  if from_address = System.get_env("MAILER_FROM_ADDRESS") do
    config :vutuv, :mailer_from, {System.get_env("MAILER_FROM_NAME") || "vutuv", from_address}
  end

  if bounce_address = System.get_env("BOUNCE_ADDRESS") do
    config :vutuv, :bounce_address, bounce_address
  end

  if appeal_reply_to = System.get_env("APPEAL_REPLY_TO") do
    config :vutuv, :appeal_reply_to, appeal_reply_to
  end

  if operator_email = System.get_env("OPERATOR_EMAIL") do
    config :vutuv,
           :operator_recipient,
           {System.get_env("OPERATOR_NAME") || operator_email, operator_email}
  end

  if operator_name = System.get_env("OPERATOR_NAME") do
    config :vutuv, :operator_name, operator_name
  end

  if operator_url = System.get_env("OPERATOR_URL") do
    config :vutuv, :operator_url, operator_url
  end

  if operator_address = System.get_env("OPERATOR_ADDRESS") do
    config :vutuv, :operator_address, operator_address
  end

  # Follow-only ActivityPub federation. FEDIVERSE_ENABLED=false turns every
  # Fediverse endpoint and delivery off — for installations that must not
  # call out (intranets). Per member it is opt-in either way.
  if System.get_env("FEDIVERSE_ENABLED") == "false" do
    config :vutuv, :fediverse_enabled, false
  end

  # Organization-page domain proof. VERIFY_ORGANIZATION_DOMAINS=false disables the DNS TXT
  # and well-known-file methods (and their periodic re-check), so no new organization
  # page can be verified — for installations that must not call out (intranets).
  # Existing verified pages keep working.
  if System.get_env("VERIFY_ORGANIZATION_DOMAINS") == "false" do
    config :vutuv, :verify_organization_domains, false
  end

  # Verified personal-webpage links. VERIFY_USER_LINKS=false disables the rel=me,
  # DNS and well-known link proofs (and their periodic re-check), so no new link
  # can be verified — for installations that must not call out (intranets).
  # Existing verified marks keep working.
  if System.get_env("VERIFY_USER_LINKS") == "false" do
    config :vutuv, :verify_user_links, false
  end

  # The per-member daily cap on outbound invitations (see Vutuv.Invitations).
  if invitation_daily_cap = System.get_env("INVITATION_DAILY_CAP") do
    config :vutuv, :invitation_daily_cap, String.to_integer(invitation_daily_cap)
  end

  # Avatars and URL screenshots are written under this root and served by
  # nginx (location /avatars/, /screenshots/). Override with UPLOADS_DIR_PREFIX;
  # the default must match the nginx alias root or fresh uploads will 404.
  config :vutuv, :uploads_dir_prefix, System.get_env("UPLOADS_DIR_PREFIX") || "/srv/legacy-vutuv"

  # URL screenshots are rendered by local headless Chromium. Set CHROMIUM_PATH
  # if the binary is not on $PATH under one of the usual names.
  config :vutuv, :chromium_path, System.get_env("CHROMIUM_PATH")

  # Post images are auth-proxied: the app checks the post's audience, then
  # serves the bytes itself with send_file (the sendfile syscall, no in-memory
  # buffering), and nginx proxies them like any other app response.
  #
  # We deliberately do NOT use the X-Accel-Redirect handoff here. It was tried
  # in production (2026-06-29) and, although the nginx `internal_post_images`
  # location is present and correct and the files are readable by the nginx
  # user, nginx rejected every X-Accel internal redirect with its bare
  # `internal` 404 instead of streaming the file, so every post image came back
  # broken. `send_file` is the path dev/test already use, so it is well tested
  # and audience-guarded identically. The `:accel_redirect` mode still exists
  # (the controller branches on this value) for if the nginx X-Accel handoff is
  # ever root-caused and re-enabled.
  config :vutuv, :post_image_serving, :send_file

  # Bearer token for POST /webhooks/bounces (the Postfix bounce pipe, see
  # docs/ADMINS.md "Email deliverability"). Unset => the endpoint 404s, bounce
  # handling is simply off; nothing else breaks.
  config :vutuv, :bounce_webhook_token, System.get_env("BOUNCE_WEBHOOK_TOKEN")

  # Optional GitHub API token for the profile code-stats fetches
  # (Vutuv.CodeStats.GitHub, see docs/ADMINS.md). Unset => unauthenticated
  # requests (60/hour per IP), which the 7-day snapshot cache is sized for;
  # set a fine-grained PAT with no scopes to raise the limit to 5,000/hour.
  # Can be added to a running installation at any time — nothing else changes.
  config :vutuv, :github_api_token, System.get_env("GITHUB_API_TOKEN")

  # The Postfix delivery log the bounce watcher tails (see
  # docs/production-email-and-bounces.md). The watcher needs read access to it
  # (add the app user to the `adm` group). Set MAIL_LOG_PATH="" to turn the
  # watcher off (it then starts and immediately :ignores).
  config :vutuv, Vutuv.Deliverability.Watcher,
    path: System.get_env("MAIL_LOG_PATH", "/var/log/mail.log"),
    poll_ms: String.to_integer(System.get_env("MAIL_LOG_POLL_MS") || "5000")
end
