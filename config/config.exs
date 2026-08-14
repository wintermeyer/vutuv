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

# Pages that are never worth a link-preview screenshot: they answer a headless
# capture with a cookie-consent banner, a login wall or a bot check, so the
# shot is a picture of a dialog rather than of the page. Skipping them (in
# Vutuv.PageScreenshot and the single-link post queue) saves the Chromium run
# instead of burning it on something that can't work.
#
# An entry is a domain or a URL, see Vutuv.ScreenshotBlocklist:
#
#     heise.de                     the site: apex + every subdomain, any path
#     *.heise.de                   the same rule spelled out
#     example.com/news             that path and everything below it
#     example.com/*/private        `*` stands for exactly one path segment
#     https://example.com/story-1  one page (the scheme is ignored)
#
# This is only the SEED a fresh installation starts with: which sites need it
# changes the day one adds a consent layer, so the live list is data in the
# `screenshot_blocklist_entries` table, edited at /admin/screenshots?tab=
# blocklist. The migration that created that table copied this list in once
# (together with SCREENSHOT_BLOCKLIST from the environment, see
# config/runtime.exs); editing it afterwards changes nothing on an installation
# that has already migrated — add the entry in the admin area instead.
config :vutuv, :screenshot_blocklist, ["reddit.com", "heise.de"]

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

# The assisted tag pass (Vutuv.Tags.Assistant, issue #1338): an admin-triggered
# batch that proposes which tags name one topic. It never merges anything — a
# human approves each proposal on /admin/tag_merges — and the candidate pairs
# are generated deterministically, so with this off (or Ollama unreachable) the
# queue still fills and is administered by hand. That is the air-gapped case.
# Runtime overrides: TAG_MERGE_ASSIST, TAG_MERGE_ASSIST_MODEL.
config :vutuv, :tag_merge_assist, true
config :vutuv, :tag_merge_assist_model, "qwen3.5:9b"

# Arbeitszeugnis analysis (Vutuv.References.Checks): a member may have an
# uploaded employment reference reviewed by a text model against an open
# skill. Shares :ollama_url with the image moderation above.
#
# :reference_check_num_ctx is NOT a tuning knob. The prompt measures ~35_200
# tokens, and a window smaller than that does not make Ollama refuse — it
# silently truncates and answers anyway. Measured against this prompt: at
# 32_768 the model saw 16_386 of 35_559 tokens and produced a polished report
# with no § 109 GewO and no Beweislast in it. 65_536 is the measured working
# value; Vutuv.References.Analyst refuses to run below what it needs and
# rejects a reply whose prompt_eval_count shows a truncation.
#
# The analysis reads GERMAN employment law (§ 109 GewO plus BAG case law), so
# :reference_check_countries lists the countries it may be offered for.
# Austria (§ 39 AngG) forbids the coded grading it decodes and Switzerland
# (Art. 330a OR) has its own case law, so a German reading of either would be
# confidently wrong. Uploading and showing a reference works everywhere.
#
# :reference_check_hardware and :reference_check_country say what the
# member-facing "how the review works" box on /settings/job_references may
# claim about where the analysis runs. The whole point of that box is that
# nothing leaves this installation, and "on our own NVIDIA GPU in Germany" is a
# stronger promise than "on our own servers" only while it is TRUE — an
# installation running Ollama on a CPU, on another vendor's card, or in another
# country sets its own values, or empty ones to drop the clause and keep the
# plain sentence. Never hardcode either in the template.
#
# The country is an ISO 3166-1 alpha-2 code, not a word, so `Vutuv.Countries`
# renders it in the reader's own language ("Deutschland" / "Germany") instead
# of one operator's spelling leaking into every locale.
#
# :reference_check_model_url is where that box links the model tag it names, so
# a reader can check the "freely available" claim for themselves. nil means
# derive it from the tag (`Analyst.model_url/0` knows the ollama.com and
# Hugging Face address shapes); an empty string means this model has no page
# anywhere and drops the link, keeping the name.
#
# Runtime overrides: REFERENCE_CHECKS_ENABLED, REFERENCE_CHECK_MODEL,
# REFERENCE_CHECK_MODEL_URL, REFERENCE_CHECK_NUM_CTX, REFERENCE_CHECK_TIMEOUT,
# REFERENCE_CHECKS_PER_DAY, REFERENCE_CHECK_HARDWARE, REFERENCE_CHECK_COUNTRY,
# FETCH_REFERENCE_SKILL, REFERENCE_OCR (config/runtime.exs).
# The one notification email: a digest of what a member missed, swept every few
# minutes by Vutuv.Activity.DigestNotifier. :notification_digest_delay_minutes is
# how long a notification may sit unread before it is mailed — long enough that
# somebody stepping away from the keyboard never gets mail about news they came
# back and read anyway.
config :vutuv, :notification_digest_delay_minutes, 30

config :vutuv, :reference_checks_enabled, true
config :vutuv, :reference_check_model, "qwen3.6:27b"
config :vutuv, :reference_check_model_url, nil
config :vutuv, :reference_check_hardware, "NVIDIA GPU"
config :vutuv, :reference_check_country, "DE"
config :vutuv, :reference_check_num_ctx, 65_536
config :vutuv, :reference_check_timeout, 900_000
config :vutuv, :reference_checks_per_day, 10
config :vutuv, :reference_check_countries, ["DE"]

# The analysis prompt ships **in this repository** (priv/reference_skill/SKILL.md)
# and that copy is what runs. It is a legal document: the prompt that was
# reviewed is the prompt that produces readings, a change to it is a reviewable
# commit, and no installation depends on GitHub being up to answer a member.
#
# The daily re-fetch from upstream is still built and tested, but it is OFF by
# default — an unreviewed overnight change to the thing that generates legal
# analysis is worse than waiting for a deploy. Switch it on only if you want
# upstream corrections without one (Vutuv.References.Skill).
config :vutuv, :fetch_reference_skill, false

# Reading a scanned reference. :auto prefers Tesseract and falls back to the
# vision model. Tesseract goes first despite scoring worse overall because its
# mistakes look like mistakes, while a vision model normalises plausibly — it
# turned "Kundenstammdaten" into "Kundendaten" in testing, and in a document
# where one word carries the grade a visible error is the safer one.
config :vutuv, :reference_ocr, :auto
config :vutuv, :reference_ocr_lang, "deu"

# The model that reads a scan, deliberately separate from :ollama_vision_model
# above: moderation wants a fast verdict on a picture, transcription wants
# every word exactly as written. Measured on a real Zeugnis template,
# qwen3-vl:8b (the moderation model) read "vollsten Zufriedenheit" as "vollen"
# — Note 1 into Note 2, in flawless German. qwen3.5:9b got every checked
# phrase right in a third of the time.
config :vutuv, :reference_ocr_model, "qwen3.5:9b"

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

# How long the composer keeps a draft nobody has touched (issue #1148). A draft
# is a convenience, not an archive: past this the composer would greet somebody
# with half a sentence they have long forgotten writing, and it keeps the photos
# attached to it alive meanwhile. Runtime override: POST_DRAFT_RETENTION_DAYS
# (config/runtime.exs).
config :vutuv, :post_draft_retention_days, 30

# How long the composer waits after the last change before it writes the draft,
# in milliseconds. The pause is what keeps ordinary typing at one write per
# pause instead of one per character; `0` writes on the spot, trading writes for
# never losing the last second of typing (which is what the test env uses).
config :vutuv, :composer_draft_debounce_ms, 1_500

# The global on/off switch for the daily text-ad system (see Vutuv.Ads).
# Off for now: no banner serves, the public /ads flow and the admin review
# dashboard 404. "ads" stays a reserved username slug either way, so the
# handle is kept free for when the system is switched back on.
config :vutuv, :ads_enabled, false

# The split test on the logged-out landing page's founder quote
# (see Vutuv.Experiments): each visitor gets one of two headlines at random
# and the views, sign-ups and PIN confirmations are counted per variant, so
# the copy is decided by what people do rather than by taste. Off = every
# visitor sees Experiments.default_landing_variant/0 and nothing is counted,
# which is what an installation that has no interest in our marketing copy
# wants. Runtime override: LANDING_HEADLINE_EXPERIMENT=false
# (config/runtime.exs). Only aggregate counters are stored, never a visitor.
config :vutuv, :landing_headline_experiment, true

# Where this installation's data physically lives, named on the start page's
# privacy section ("on our own servers in Deutschland, not in somebody else's
# cloud"). Empty drops that whole claim and leaves only the three promises the
# SOFTWARE makes on every installation: no third-party cookies, export your data
# whenever you like, delete your account yourself.
#
# Set it only if it is true for you. An operator running vutuv on rented cloud
# infrastructure must clear it — the sentence says "our own servers", and a
# start page that claims otherwise is worse than one that says nothing.
# Runtime override: DATA_LOCATION (config/runtime.exs).
config :vutuv, :data_location, "Deutschland"

# The one profile the logged-out start page offers as "try it out" beside the
# screenshots of a filled-in profile. A full URL, because the point is a page
# somebody can open and read without an account, and because the default has to
# keep working on an installation that has no members yet — pointing at the
# reference installation is more useful there than a dead local link.
# Set it to one of your own members once you have one, or to "" to drop the
# line. Runtime override: LANDING_EXAMPLE_PROFILE_URL (config/runtime.exs).
config :vutuv, :landing_example_profile_url, "https://vutuv.de/wintermeyer"

# Follow-only ActivityPub federation (Vutuv.Fediverse): people on Mastodon
# & Co. can follow opted-in members and receive their public posts. Off =
# every Fediverse endpoint 404s and nothing is ever delivered — the switch
# for installations that must not call out (intranets). Runtime override:
# FEDIVERSE_ENABLED=false (config/runtime.exs). Per member it stays opt-in
# either way (users.fediverse_followers?).
config :vutuv, :fediverse_enabled, true

# Whether the hourly GenServer that re-checks remote followers runs (off in
# tests, where it would touch the SQL sandbox from outside; tests call
# Vutuv.Fediverse.prune_due_followers/1 directly). It drops a follower row
# whose remote account answers 404/410 — the accounts that vanished without
# an Undo or a Delete. A no-op anyway while :fediverse_enabled is off.
config :vutuv, :fediverse_follower_pruning, true

# Whether the hourly GenServer that deletes expired remote replies runs (off in
# tests, same sandbox reasoning; tests call Vutuv.Fediverse.expire_due_notes/1
# directly). A no-op while :fediverse_enabled is off.
config :vutuv, :fediverse_note_sweeping, true

# Whether opening a page queues the freshness re-fetch for the stale replies on
# it (off in tests, where it would run outside the SQL sandbox). Off, the hard
# ceiling still governs; on, a reply confirmed still published at its origin
# refreshes and pushes its ceiling out, and one that is gone is deleted early.
config :vutuv, :fediverse_note_refresh, true

# How long a reply written on another network may be held here (issues #1069 and
# #1071), and how stale a stored copy may get before its origin is asked whether
# it is still published there.
#
# The two work as a pair: the ceiling is the promise the privacy page makes and
# fires whatever else happens, while a note confirmed still live pushes that date
# forward, so a reply people keep reading tracks its original and one nobody has
# opened in six months is collected. An operator holding a stranger's words has
# to be able to set both, so they are env-overridable
# (FEDIVERSE_NOTE_RETENTION_DAYS / FEDIVERSE_NOTE_REFRESH_DAYS in
# config/runtime.exs).
config :vutuv, :fediverse_note_retention_days, 183
config :vutuv, :fediverse_note_refresh_days, 7

# How long a post by an account a member follows may be held here (issue #1161).
#
# The same clock and the same reasoning as the replies above, for the same
# reason: consent from somebody who never signed up here is not obtainable, so
# the copy is bounded instead. There is deliberately no refresh knob to match —
# a followed account's stream is pushed to us continuously, so an edit or a
# withdrawal arrives on its own, and re-asking about every cached post of every
# account our members read would be far heavier than the per-reply check.
# Env-overridable (FEDIVERSE_POST_RETENTION_DAYS).
config :vutuv, :fediverse_post_retention_days, 183

# Whether the GenServer that keeps the like and repost figures of cached remote
# objects current runs (issue #1283). Off in tests, where it would talk to the
# network from outside the SQL sandbox; tests call
# Vutuv.Fediverse.refresh_counts/1 and refresh_due_counts/0 directly. A no-op
# while :fediverse_enabled is off.
config :vutuv, :fediverse_counts, true

# How often a cached post or reply is re-asked for its origin's own figures,
# by the age of the object itself: `{age in minutes, re-ask every N minutes}`,
# youngest tier first. Past the last tier the numbers stand as they are and
# nothing is asked again — a two-week-old post's tally does not move, and an
# installation should not pay for asking.
#
# The first hour and a half is where a post's tally actually moves, so the head
# of the ladder is fine-grained: every five minutes for the first half hour,
# then every ten for the next hour, before it settles into the quarter-hourly
# tier and fades out from there.
#
# Five minutes is the floor and it is a deliberate one: the servers that serve
# these collections advertise `cache-control: max-age=180`, so a five-minute
# ask still sits outside what the origin itself expects to be re-asked within.
# Env-overridable (FEDIVERSE_COUNTS_LADDER, see config/runtime.exs) for an
# operator who wants to be quieter.
config :vutuv, :fediverse_counts_ladder, [
  {30, 5},
  {90, 10},
  {6 * 60, 15},
  {48 * 60, 60},
  {7 * 24 * 60, 360}
]

# The ceilings on one refresh run: how many objects in total, and how many of
# them may belong to any single host. The per-host cap is the neighbourly one —
# one instance hosting many of the accounts our members follow must not be
# fetched in a burst — and the total cap protects our own boxes, so a backlog
# drains over several runs instead of in one spike.
config :vutuv, :fediverse_counts_batch, 60
config :vutuv, :fediverse_counts_per_host, 10

# How long a post whose picture the AI image scan has not judged yet waits before
# it federates anyway (issue #1070). The scan normally settles within seconds and
# releases the post at once, so this is the CEILING, not the usual wait: it is
# what happens when the scanner is down, and then the post goes out without the
# unvetted picture rather than not at all.
config :vutuv, :fediverse_image_hold_seconds, 90

# How many answers to other networks one member may send per hour (issue #1070).
# The one place a member's own action makes vutuv POST to a server that never
# followed them, so it is metered; sized for a conversation, not a script.
config :vutuv, :fediverse_outbound_reply_limit, 30

# How many likes of posts on other networks one member may send per hour (issue
# #1164). Its own budget, and a far larger one: a like is one tap while reading,
# so a limit sized for writing prose would refuse ordinary reading. Taking a
# like back is never metered.
config :vutuv, :fediverse_outbound_like_limit, 200

# How many reposts of other networks' posts one member may send per hour (issue
# #1166). Between the two above: a boost is a publishing act, not a tap, but it
# is still one press while reading rather than a piece of writing.
config :vutuv, :fediverse_outbound_boost_limit, 100

# How many announced objects may be dereferenced from one remote host per hour
# (issue #1167). A followed account boosting is the one inbound activity that
# makes this installation fetch from a THIRD server it never spoke to, on an
# address that server did not choose, so it is metered per host.
config :vutuv, :fediverse_announce_fetch_limit, 60

# How many posts one member may look up by URL per hour (issue #1211). Metered
# per member rather than per host: the address is theirs to choose, so what has
# to be bounded is one account turning the installation into a crawler. A post
# already cached here costs nothing from the budget.
config :vutuv, :fediverse_lookup_limit, 30

# Following accounts on other networks (issue #1160): how many follow requests
# one member may send per hour, and how many accounts they may follow at all.
#
# The hourly budget is the abuse backstop — a compromised account must not be
# able to walk a whole server's member list — while the ceiling bounds the
# standing invitation each accepted follow is, since every one of them lets
# another server deliver here. Both env-overridable
# (FEDIVERSE_REMOTE_FOLLOW_LIMIT / FEDIVERSE_MAX_REMOTE_FOLLOWS).
# Pictures from the accounts a member follows (issue #1163): the per-file
# ceiling on a downloaded image.
#
# A picture is the one thing here whose *size* is the attack, so the ceiling is
# per file and the stream is halted at it rather than buffered and measured
# afterwards. Generous enough for a real photo off a phone, small enough that
# one delivery cannot cost a hundred megabytes. Env-overridable
# (FEDIVERSE_MEDIA_MAX_BYTES).
config :vutuv, :fediverse_media_max_bytes, 8_000_000

# Whether the background task that downloads those pictures runs (off in tests,
# where it would touch the SQL sandbox from outside; tests call
# Vutuv.Fediverse.Media.fetch_now/1 directly). A no-op while :fediverse_enabled
# is off. Nothing it stores is ever shown before the AI image gate clears it, so
# this switch is about the download, not about the display.
config :vutuv, :fediverse_media_fetch, true

config :vutuv, :fediverse_remote_follow_limit, 30
config :vutuv, :fediverse_max_remote_follows, 1_000

# Whether the daily GenServer that prunes the account-activity log runs (off in
# tests, same sandbox reasoning; tests call
# Vutuv.AccountEvents.delete_expired/0 directly).
config :vutuv, :sweep_account_events, true

# How long an account-activity event is kept (issue #1087). The log is personal
# data — devices, IP addresses, what changed when — so it ages out. One year
# covers the "this happened months ago and I only noticed now" support case
# without turning the table into a permanent movement profile. Per-installation
# via ACCOUNT_EVENT_RETENTION_DAYS in config/runtime.exs.
config :vutuv, :account_event_retention_days, 365

# The site-wide AI-crawler stance (see VutuvWeb.ContentPolicy): :permissive
# welcomes search, live AI input AND model training; :block_training keeps
# retrieval but declares ai-train=no and blocks the training crawlers in
# robots.txt. Flipping this also flips the Content-Signal header every
# agent document and feed sends — one policy, declared everywhere.
config :vutuv, :ai_crawler_policy, :permissive

# The live people counter (Vutuv.PeopleCounter) re-reads the authoritative
# member count and the Fediverse head count from the database on slow timers.
# Tests turn this off so its process never uses the SQL Sandbox connection it
# does not own.
config :vutuv, :reconcile_people_count, true

# The "most followed members" pool (Vutuv.Social.PopularUsers) re-ranks on a
# slow timer. Tests turn this off (sandbox ownership); every call then falls
# back to the direct ranking query, so tests always see fresh data.
config :vutuv, :refresh_popular_users, true
# Same deal for the "who to follow" recent-poster pool (Vutuv.Posts.TopPosters)
# and the feed rail's suggested-posts pool (Vutuv.Posts.PopularPosts).
config :vutuv, :refresh_top_posters, true
config :vutuv, :refresh_popular_posts, true

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

# Post images: capped per post, and generous per file — a photo post carries
# somebody's actual work (issue #1104), and a full-frame camera's JPEG runs
# well past the 6 MB this used to allow, so the limit was rejecting exactly
# the uploads the feature exists for. 50 MB sits under the endpoint's 64 MB
# multipart limit and nginx's matching `client_max_body_size` (docs/ADMINS.md),
# both of which must stay above it.
#
# Derived versions are AVIF; originals stay private on disk, and leave only
# through the per-photo download an author switches on (Vutuv.PostImageStore).
config :vutuv, :post_images, max_filesize: 50_000_000, max_per_post: 10

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

# Verified social-media handles: whether a member may prove a listed account is
# really theirs and earn the same small verified mark. Only Bluesky can be
# proved today — its profile bio must carry the member's vutuv profile URL,
# since the network has no rel=me. On = the /settings/social_media_accounts
# verify page offers the proof and re-checks it periodically; off = disabled on
# this installation (no outbound calls), so no new account can be verified
# (existing marks keep working). Runtime override: VERIFY_SOCIAL_ACCOUNTS=false.
# Tests turn it off and stub HTTP per test via :bluesky_req_options.
config :vutuv, :verify_social_accounts, true

# Whether the hourly GenServer that re-checks verified social accounts runs (off
# in tests, where it would touch the SQL sandbox from outside; tests call
# Vutuv.Profiles.SocialAccountVerification.recheck/1 directly). The re-check
# itself is also a no-op when :verify_social_accounts is off.
config :vutuv, :recheck_social_accounts, true

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

# How this installation names and describes itself to the fediverse's directory
# layer (`Vutuv.NodeInfo`, the /.well-known/nodeinfo document). FediDB,
# the-federation.info and Fediverse Observer print these two strings beside the
# entry, so they are the installation's own words, not vutuv's — one language,
# since NodeInfo has no locale negotiation. (NODE_NAME / NODE_DESCRIPTION)
config :vutuv, :node_name, "vutuv"

config :vutuv,
       :node_description,
       "The open business network where professionals connect, share, and get found."

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
