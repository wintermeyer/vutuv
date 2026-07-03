import Config

config :vutuv, VutuvWeb.Endpoint,
  # Phoenix resolves the webserver from config[:adapter] (Phoenix.Endpoint
  # .Supervisor), defaulting to Cowboy2Adapter when unset — the `adapter:`
  # option on `use Phoenix.Endpoint` does not feed runtime resolution. This
  # app runs on Bandit, so select it here.
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: VutuvWeb.ErrorHTML, json: VutuvWeb.ErrorJSON], layout: false],
  pubsub_server: Vutuv.PubSub,
  # Signs the LiveView session token exchanged over the /live socket. Distinct
  # from secret_key_base and from the Plug.Session signing_salt.
  live_view: [signing_salt: "PHEbY7u44Jfd3Ei0"],
  locales: ~w(en de),
  max_image_filesize: 2_000_000,
  max_page_items: 250

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :phoenix, :generators,
  migration: true,
  binary_id: true

config :vutuv, ecto_repos: [Vutuv.Repo]

# Every id is a UUID v7 (Vutuv.UUIDv7); new migrations default to binary_id
# columns so `create table` / `references` need no per-call type overrides.
config :vutuv, Vutuv.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id]

# Best-effort background work spawned from request handling. Both run under
# Vutuv.TaskSupervisor; the flags let tests disable them so the SQL Sandbox
# connection is never used by a process that does not own it (and so the test
# suite makes no live HTTP request / Chromium launch).
config :vutuv, :generate_screenshots, true
config :vutuv, :fetch_gravatar, true

# The global on/off switch for the daily text-ad system (see Vutuv.Ads).
# Off for now: no banner serves, the public /ads flow and the admin review
# dashboard 404. "ads" stays a reserved username slug either way, so the
# handle is kept free for when the system is switched back on.
config :vutuv, :ads_enabled, false

# The site-wide AI-crawler stance (see VutuvWeb.ContentPolicy): :permissive
# welcomes search, live AI input AND model training; :block_training keeps
# retrieval but declares ai-train=no and blocks the training crawlers in
# robots.txt. Flipping this also flips the Content-Signal header every
# agent document and feed sends — one policy, declared everywhere.
config :vutuv, :ai_crawler_policy, :permissive

# The live member counter (Vutuv.Accounts.MemberCounter) re-reads the
# authoritative user count from the database on a slow timer. Tests turn this
# off so its process never uses the SQL Sandbox connection it does not own.
config :vutuv, :reconcile_member_count, true

# The "most followed members" pool (Vutuv.Social.PopularUsers) re-ranks on a
# slow timer. Tests turn this off (sandbox ownership); every call then falls
# back to the direct ranking query, so tests always see fresh data.
config :vutuv, :refresh_popular_users, true

# The inline Mastodon posts on profile Social Media cards (Vutuv.Mastodon).
# Tests turn this off: every profile LiveView test performs a connected mount
# and must never fetch a federated instance (Mastodon tests flip it on
# per-test and stub HTTP via :mastodon_req_options).
config :vutuv, :fetch_mastodon_posts, true

# Post images: larger than avatars (6 MB), capped per post. Derived versions
# are WebP; originals stay private on disk (see Vutuv.PostImageStore).
config :vutuv, :post_images, max_filesize: 6_000_000, max_per_post: 10

# The SMTP envelope sender (Sender header -> MAIL FROM) for all outbound
# mail: bounces (DSNs) come back to this one mailbox, which production
# Postfix pipes into POST /webhooks/bounces (see Vutuv.Notifications.Bounces).
config :vutuv, :bounce_address, "bounces@vutuv.de"

# The visible From (no-reply@vutuv.de) is not read, but the strike-3
# deactivation mail invites the member to appeal by replying. That one mail
# carries a Reply-To to this monitored contact so an appeal reaches a human
# (see Vutuv.Notifications.Emailer.moderation_deactivation_email/2).
config :vutuv, :appeal_reply_to, "sw@wintermeyer-consulting.de"

# Mail is delivered via SMTP (prod) and the Local/Test adapters elsewhere, none
# of which need an HTTP API client. Disabling it avoids pulling in hackney.
config :swoosh, :api_client, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.0",
  vutuv: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  vutuv: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"

if File.exists?("config/#{config_env()}.secret.exs") do
  import_config "#{config_env()}.secret.exs"
end
