import Config

config :vutuv, VutuvWeb.Endpoint,
  # Phoenix resolves the webserver from config[:adapter] (Phoenix.Endpoint
  # .Supervisor), defaulting to Cowboy2Adapter when unset — the `adapter:`
  # option on `use Phoenix.Endpoint` does not feed runtime resolution. This
  # app runs on Bandit, so select it here.
  adapter: Bandit.PhoenixAdapter,
  # The exception-rescued error path wraps the ErrorHTML card in a
  # **self-contained** layout (VutuvWeb.LayoutHTML.error/1, templates/layout/
  # error.html.heex): a full HTML document with inline critical CSS, so a
  # rescued 500 looks like vutuv.de even when the DB or the /assets pipeline is
  # the thing that broke. It must NOT be `false` (that shipped a bare, unstyled
  # serif error page); error_layout_test.exs fails the build if it regresses.
  render_errors: [
    formats: [html: VutuvWeb.ErrorHTML, json: VutuvWeb.ErrorJSON],
    # Format-qualified (`html: {...}`), not the bare 2-tuple: RenderErrors
    # passes this straight to put_layout/2, and the bare form conflicts with
    # the pipeline's `html: {LayoutHTML, :app}` and logs a soft-deprecation
    # warning on every rescued 500.
    layout: [html: {VutuvWeb.LayoutHTML, :error}]
  ],
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

# The ActivityPub media type (follow-only federation, Vutuv.Fediverse): the
# :browser pipeline must let an `Accept: application/activity+json` request
# through to the profile / post-permalink controllers, which answer it with
# the actor / Note documents. Changing this map requires recompiling the mime
# dep once (mix deps.clean --build mime).
config :mime, :types, %{
  "application/activity+json" => ["activity+json"]
}

config :phoenix, :generators,
  migration: true,
  binary_id: true

config :vutuv, ecto_repos: [Vutuv.Repo]

# Every id is a UUID v7 (Vutuv.UUIDv7); new migrations default to binary_id
# columns so `create table` / `references` need no per-call type overrides.
#
# disconnect_on_error_codes: a migration that widens a column type (e.g. the
# varchar -> text description widen) invalidates the old release's cached
# prepared statements, and Postgres answers them with 0A000
# :feature_not_supported ("cached plan must not change result type"). Dropping
# the connection on that code makes the pool re-prepare on fresh connections
# immediately instead of erroring once per cached statement — keeps the
# still-serving release healthy through blue/green migrations.
config :vutuv, Vutuv.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  disconnect_on_error_codes: [:feature_not_supported]

# Best-effort background work spawned from request handling. Both run under
# Vutuv.TaskSupervisor; the flags let tests disable them so the SQL Sandbox
# connection is never used by a process that does not own it (and so the test
# suite makes no live HTTP request / Chromium launch).
config :vutuv, :generate_screenshots, true
config :vutuv, :fetch_gravatar, true

# AI image moderation (Vutuv.Moderation.ImageScans): every image — uploads
# and machine-generated screenshots alike — is held in owner-only limbo until
# an Ollama vision model releases it; unsafe images are deleted and the
# owner notified. Fail-closed: with Ollama unreachable the queue retries
# forever, nothing is auto-approved. Off = images release immediately (tests,
# installations without Ollama). :ollama_url may be a comma-separated
# priority list — every instance but the last is tried with the short
# :ollama_remote_timeout and skipped on any service failure; the last is the
# patient fallback of record (:ollama_timeout). Runtime overrides:
# IMAGE_MODERATION_ENABLED, OLLAMA_URL, OLLAMA_VISION_MODEL
# (config/runtime.exs).
config :vutuv, :moderate_images, true
config :vutuv, :ollama_url, "http://localhost:11434"
config :vutuv, :ollama_vision_model, "qwen3-vl:8b"

# How a suspicion becomes a deletion. A model's answer on a borderline but
# harmless picture (a cartoon skull, a horror-film still, a joke image) flips
# between runs, so an "unsafe" answer is put to a vote of :image_scan_votes
# independent opinions and the image is deleted only if
# :image_scan_reject_votes of them agree. Unanimous out of three: deleting a
# member's picture on a coin flip is the worse error, and a released image is
# still reportable. A safe first answer decides alone, so the ordinary upload
# costs one inference. Both at 1 = the old single-opinion behaviour.
config :vutuv, :image_scan_votes, 3
config :vutuv, :image_scan_reject_votes, 3

# How many minutes a post stays editable after publishing (issue #1023). An
# edit rewrites what readers already liked or reposted, so editing closes with
# the first like, repost or reply anyway (Vutuv.Posts.editable?/1); this is the
# grace period for the typo you spot right after posting. Runtime override:
# POST_EDIT_WINDOW_MINUTES (config/runtime.exs).
config :vutuv, :post_edit_window_minutes, 30

# The global on/off switch for the daily text-ad system (see Vutuv.Ads).
# Off for now: no banner serves, the public /ads flow and the admin review
# dashboard 404. "ads" stays a reserved username slug either way, so the
# handle is kept free for when the system is switched back on.
config :vutuv, :ads_enabled, false

# Follow-only ActivityPub federation (Vutuv.Fediverse): people on Mastodon
# & Co. can follow opted-in members and receive their public posts. Off =
# every Fediverse endpoint 404s and nothing is ever delivered — the switch
# for installations that must not call out (intranets). Runtime override:
# FEDIVERSE_ENABLED=false (config/runtime.exs). Per member it stays opt-in
# either way (users.fediverse_followers?).
config :vutuv, :fediverse_enabled, true

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

# The inline social posts on profiles (Vutuv.SocialFeed), one flag per
# provider. Tests turn them off: every profile LiveView test performs a
# connected mount and must never fetch a remote network (the feed tests flip
# them on per-test and stub HTTP via :mastodon_req_options /
# :bluesky_req_options).
config :vutuv, :fetch_mastodon_posts, true
config :vutuv, :fetch_bluesky_posts, true

# Wall-clock ceiling for a single newsletter send (test or broadcast). gen_smtp
# bounds only its *connect* with the :timeout option; each per-response read
# uses a hardcoded, non-configurable 20-minute timeout, so a black-holing relay
# that keeps the socket open can otherwise freeze a broadcast far past the
# 5-minute stuck-detection window (Vutuv.Newsletters.stuck_newsletters/1) and
# trip a false resume that double-mails the un-logged tail (#943). Bounding each
# send keeps a delivery row landing well within that window, so a live-but-slow
# broadcast never looks stuck. A timed-out send is logged "error" and the loop
# moves on. Override per installation with NEWSLETTER_SEND_TIMEOUT_SECONDS
# (runtime.exs) - relevant mainly for remote-smarthost setups.
config :vutuv, :newsletter_send_timeout_ms, :timer.seconds(60)

# The cached public code-forge statistics on profiles (Vutuv.CodeStats:
# GitHub, GitLab, Codeberg — the profile's "Code" card). Off = the accounts
# stay plain links and nothing is ever fetched — the switch for installations
# that must not call out (intranets). Tests turn it off and stub HTTP per
# provider via :github_req_options / :gitlab_req_options /
# :codeberg_req_options. The optional GITHUB_API_TOKEN env var
# (config/runtime.exs) raises GitHub's unauthenticated 60 requests/hour to
# 5,000/hour; see docs/ADMINS.md.
config :vutuv, :fetch_code_stats, true

# Book metadata for post reviews (Vutuv.BookMetadata: the composer's ISBN →
# title/author/year prefill; Vutuv.Posts.ReviewCovers: the cover image plus
# the page count and publisher on the review card; Vutuv.AudiobookLength: an
# audiobook's running time). The first two come keyless from Open Library,
# the third from a library catalogue (:dnb_sru_url below). Off = nothing is
# ever fetched — the switch for installations that must not call out
# (intranets); the review card then renders without a cover and the fields
# are typed by hand. Runtime override: FETCH_BOOK_METADATA=false
# (config/runtime.exs). Tests keep it off and stub HTTP via
# :book_metadata_req_options / :book_covers_req_options / :dnb_req_options.
config :vutuv, :fetch_book_metadata, true

# Where an audiobook's running time is looked up: an SRU endpoint answering
# MARC21-xml, queried by ISBN (Vutuv.AudiobookLength reads MARC field 300,
# where a catalogue states "2 CDs (ca. 136 Min.)"). Open Library records no
# durations, so this is a second, deliberately German source — the Deutsche
# Nationalbibliothek, keyless. An empty DNB_SRU_URL switches the lookup off;
# another catalogue's SRU endpoint can take its place (config/runtime.exs).
config :vutuv, :dnb_sru_url, "https://services.dnb.de/sru/dnb"

# The shop link on a book review card: https://<domain>/dp/<isbn10> (search
# fallback for 979 ISBNs), with an optional Amazon affiliate tag appended as
# ?tag=. An empty AMAZON_DOMAIN removes the link entirely (config/runtime.exs
# overrides both), so every installation chooses its own store — or none.
config :vutuv, :amazon_domain, "www.amazon.de"
config :vutuv, :amazon_affiliate_tag, nil

# The audiobook link on a book review card: an Audible search for the book by
# title + author (Audible keys its audiobooks by their own ASIN, not the print
# ISBN we store, so a direct product link isn't derivable). An empty
# AUDIBLE_DOMAIN removes the link (config/runtime.exs overrides it), so every
# installation points at its own Audible store — or none.
config :vutuv, :audible_domain, "www.audible.de"

# Post images: larger than avatars (6 MB), capped per post. Derived versions
# are WebP; originals stay private on disk (see Vutuv.PostImageStore).
config :vutuv, :post_images, max_filesize: 6_000_000, max_per_post: 10

# Job-posting images: same pattern and limits as post images.
config :vutuv, :job_posting_images, max_filesize: 6_000_000, max_per_post: 10

# Job postings (Vutuv.Jobs, milestone 11).
#   * default_runtime_days — how long a published posting stays live before it
#     auto-expires. Flat, no renewals: a still-open role gets a fresh posting.
#   * max_published_per_member / _organization — anti-abuse concurrency caps.
# Runtime overrides: JOB_RUNTIME_DAYS, JOBS_MAX_PER_MEMBER, JOBS_MAX_PER_ORG.
config :vutuv, :jobs,
  default_runtime_days: 90,
  max_published_per_member: 3,
  max_published_per_organization: 10

# Cold-outreach cap (Vutuv.Chat): the anti-spam ceiling on how many new message
# *requests* one member may open to strangers (members who don't already follow
# them) within :window_ms. Replying to an accepted thread never counts. A
# generous default so a pushy recruiter is throttled long before a legitimate
# one is. Runtime overrides: COLD_OUTREACH_LIMIT, COLD_OUTREACH_WINDOW_HOURS.
config :vutuv, :cold_outreach,
  limit: 20,
  window_ms: 24 * 60 * 60 * 1000

# Saved searches with e-mail alerts (Vutuv.SavedSearches, issue #935). The
# per-member cap on how many searches one member may store — a plain anti-abuse
# ceiling, identical for everyone (not a member preference). Runtime override:
# SAVED_SEARCHES_MAX_PER_MEMBER.
config :vutuv, :saved_searches, max_per_member: 10

# Offline structured location (Vutuv.Geo). :geo_countries lists which bundled
# GeoNames postal datasets (priv/geo/<CC>.txt[.gz]) to load for zip → lat/lon
# resolution; :default_country preselects country inputs. No outbound calls —
# intranet-safe. Runtime overrides: GEO_COUNTRIES (comma list), DEFAULT_COUNTRY.
config :vutuv, :geo_countries, ~w(DE AT CH)
config :vutuv, :default_country, "DE"

# Verified organization pages (Vutuv.Organizations): the domain-proof methods, a DNS TXT
# record and a well-known file. Both prove control of the DOMAIN itself, never
# merely an address on it (an e-mail code would let anyone with a @gmail.com
# address claim the gmail.com page). On = the claim wizard offers both and
# re-checks them periodically; off = organization domain verification is disabled on
# this installation (no outbound calls), so no new organization page can be created
# (existing verified pages keep working). Runtime override:
# VERIFY_ORGANIZATION_DOMAINS=false. Tests turn it off and stub DNS / HTTP per test
# via :organizations_dns_resolver / :organizations_req_options.
config :vutuv, :verify_organization_domains, true

# Verified personal-webpage links: whether a member may prove a profile link is
# their own webpage (a rel=me back-link, or the same DNS / well-known domain
# proof organizations use) and earn a small verified mark. On = the /settings/links
# verify page offers the methods and re-checks them periodically; off = link
# verification is disabled on this installation (no outbound calls), so no new
# link can be verified (existing marks keep working). Runtime override:
# VERIFY_USER_LINKS=false. Tests turn it off and stub DNS / HTTP per test via
# :user_links_dns_resolver / :user_links_req_options.
config :vutuv, :verify_user_links, true

# Whether the hourly GenServer that re-checks verified links runs (off in tests,
# where it would touch the SQL sandbox from outside; tests call
# Vutuv.Profiles.LinkVerification.recheck/1 directly). The re-check itself is
# also a no-op when :verify_user_links is off.
config :vutuv, :recheck_user_links, true

# The most invitations a single member may send in one Berlin calendar day
# (see Vutuv.Invitations) — the abuse guard on outbound invite email, which
# protects the installation's sender reputation. Tune it per installation
# (a small intranet may want it higher/lower). Runtime override:
# INVITATION_DAILY_CAP (config/runtime.exs).
config :vutuv, :invitation_daily_cap, 50

# --- Operator identity ------------------------------------------------------
# Everything naming the party who runs THIS installation lives behind these
# keys, so another organization can run vutuv without editing source. The defaults
# are the vutuv.de values; config/runtime.exs overrides each from an
# environment variable at boot (names in parentheses). The legal pages
# (Impressum etc.) are per-installation data too — see Vutuv.Legal.

# The visible From ({name, address}) on every outbound email
# (MAILER_FROM_NAME / MAILER_FROM_ADDRESS).
config :vutuv, :mailer_from, {"vutuv", "no-reply@vutuv.de"}

# The SMTP envelope sender (Sender header -> MAIL FROM) for all outbound
# mail: bounces (DSNs) come back to this one mailbox, which production
# Postfix pipes into POST /webhooks/bounces (see Vutuv.Notifications.Bounces).
# (BOUNCE_ADDRESS)
config :vutuv, :bounce_address, "bounces@vutuv.de"

# Keep the email-deliverability ops alarms visible even where the global
# Logger level is quiet (production runs :error): Vutuv.Application raises the
# watcher/bounce/emailer modules to :info at boot. Off only in tests.
config :vutuv, :ops_log_visibility, true

# The visible From (no-reply@vutuv.de) is not read, but the strike-3
# deactivation mail invites the member to appeal by replying. That one mail
# carries a Reply-To to this monitored contact so an appeal reaches a human
# (see Vutuv.Notifications.Emailer.moderation_deactivation_email/2).
# (APPEAL_REPLY_TO)
config :vutuv, :appeal_reply_to, "sw@wintermeyer-consulting.de"

# Who receives the operator notices (daily report, ad bookings, account-
# deleted records) — never a member-facing address. Also the security.txt
# contact. (OPERATOR_NAME / OPERATOR_EMAIL)
config :vutuv, :operator_recipient, {"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}

# The operator credit in the site and email footers ("a service provided
# by ..."), and the one-line postal address every email footer carries.
# (OPERATOR_NAME / OPERATOR_URL / OPERATOR_ADDRESS)
config :vutuv, :operator_name, "Wintermeyer Consulting"
config :vutuv, :operator_url, "https://wintermeyer-consulting.de"
config :vutuv, :operator_address, "Johannes-Müller-Str. 10 - 56068 Koblenz - Germany"
# -----------------------------------------------------------------------------

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
