# vutuv

vutuv is a free, fast and open source social network service to host and share information about humans and organizations. It's hosted at https://vutuv.de.

We use [MIT License](https://mit-license.org/).

## Development Setup

vutuv is a [Phoenix Framework](https://www.phoenixframework.org/) 1.8 application. Install the following prerequisites using [mise](https://mise.jdx.dev/) (see `.tool-versions`):

- Erlang 28.5.0.1
- Elixir 1.20.0-otp-28
- [PostgreSQL](https://www.postgresql.org/) 17

Two system libraries are also required (not managed by mise):

- **libvips** — all image processing (avatars, cover photos, post images, URL screenshots) goes through the [`image`](https://hex.pm/packages/image) package, which needs libvips. Install with `brew install vips` (macOS) or `apt-get install libvips-dev` (Debian/Ubuntu).
- **Chromium** (optional) — only needed for URL screenshots and moderation evidence screenshots; set `CHROMIUM_PATH` if the binary is not on `$PATH`.

No Node.js is required: esbuild and Tailwind are installed as Elixir deps via `mix assets.setup`.

All database ids are UUID v7 (`Vutuv.UUIDv7`): time-ordered, minted in the app, never integers or UUID v4.

### Secret config

Create `config/dev.secret.exs`:
```elixir
import Config

config :vutuv, VutuvWeb.Endpoint,
  secret_key_base: "generate-with-mix-phx-gen-secret"
```

### Start the application

```bash
mix deps.get
mix assets.setup    # install esbuild + tailwind
mix ecto.create
mix ecto.migrate
mix phx.server
```

Visit http://localhost:4000.

### Email in development

Emails are displayed in the browser via Swoosh's mailbox preview at http://localhost:4000/sent_emails.

Every vutuv email is machine-generated, so all of it carries the `Auto-Submitted: auto-generated` (RFC 3834) and `X-Auto-Response-Suppress: All` headers to keep out-of-office and other auto-responders silent. Mail is built from `Vutuv.Notifications.Emailer.base_email/0` and sent through the single `Emailer.deliver/1` chokepoint, the only place allowed to call `Vutuv.Mailer.deliver/1`.

### AI tooling in development

[Tidewave](https://tidewave.ai) runs in the dev server (dev-only dependency): AI coding agents can connect to the MCP endpoint at http://localhost:4000/tidewave/mcp to eval code in the running app, query Ecto and read logs.

### Admin access

Flag your account as admin (the column is `admin?`, so it must be quoted; match
on your handle since ids are UUIDs):
```sql
UPDATE users SET "admin?" = true WHERE active_slug = 'your-handle';
```

Admin panel: http://localhost:4000/admin

A logged-in member without admin rights who opens `/admin` gets a 403 page that explains exactly this: admin rights are granted by the instance operator directly in the database (contact via Impressum).

## Architecture

- **Views**: mostly Phoenix 1.8 HTML modules with `embed_templates` (no `phoenix_view` dependency); **LiveView is being adopted incrementally** for the real-time parts (see below)
- **Real-time shell (LiveView)**: the app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with live unread badges) is embedded in the shared `app` layout via `live_render`, so the chrome and badges are live on every page. The **Messages** (`/messages`), **Notifications** (`/notifications`), **Feed** (`/feed`) and **Search** (`/search`) pages are LiveViews under a `live_session`; search is search-as-you-type (results from three letters on, exact and similar-sounding name matches clearly separated, `?q=` plus the filters keeps the URL shareable and a settled query is recorded once) with scope chips (all/people/tags/posts), an exact-only toggle and query operators parsed by `Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aka `first:`/`last:`), `@handle`, double quotes for exact, plus the combinable people filters `tag:`/`skill:` (has the tag) and `ort:`/`stadt:`/`city:` (address in that city) - e.g. `müller tag:php` or `müller ort:koblenz`. In-app updates flow over `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"`); online status and typing use `VutuvWeb.Presence`. A **site-wide online dot** (green badge on a member's avatar everywhere — lists, profiles, post authors, the top bar) rides the same `VutuvWeb.Presence`: the always-present shell tracks the current member online on one global topic and pushes each viewer their own online-id set to a tiny JS hook that toggles the dot on every `<.avatar presence>` in the page (classic controller pages included). It is public **except across a block** (the shell filters each viewer's set both ways) and each member can switch it off on the Privacy settings page (`show_online_status?`), after which they are never tracked or shown as online. The layout is split into `root.html.heex` (document shell) and `app.html.heex` (chrome), shared by classic controller pages and LiveViews. Notifications are real data **derived at read time** from the existing event tables (followers, endorsements, connections — accepted ones and pending incoming requests —, replies, likes; retroactively, no notifications table); each entry links to what it reports (the post, the requests page, the actor's profile). The only stored state is the `users.notifications_read_at` read marker behind the unread badge.
- **Live member counter**: the logged-out landing page shows the **exact** number of members and ticks it up in real time as people register. `Vutuv.Accounts.MemberCounter` keeps the total in a lock-free `:atomics` cell (ref in `:persistent_term`), so the per-render read (`count/0`) and the per-signup bump (`increment/0`, called from `Accounts.register_user/2`) are O(1) and never hit the database — a signup spike just races on one atomic add. A single owner GenServer seeds the cell from the DB at boot, re-reads the authoritative count on a slow timer (self-healing against deletions), and broadcasts the value only when it changed, so a burst of signups coalesces into at most one PubSub message per tick instead of a fan-out storm. The pill is the embedded `VutuvWeb.MemberCountLive` (rendered via `live_render`, like the shell).
- **Follow + connect (the social graph)**: two distinct relationships (`Vutuv.Social`). A **follow** (`Vutuv.Social.Follow`, table `follows`) is a one-directional subscription — follow anyone, no approval — and decides whose posts reach your `/feed`. A **connection** (`Vutuv.Social.Connection`) is mutual and consented: you request it, the other party accepts or declines (silently, with a re-request cooldown), and acceptance auto-creates a follow in **both** directions — which either side can then drop while staying connected, so "connected but not following" is a real state. The profile header carries both controls (`<.connect_control>` + `<.follow_button>`); requests/accepts push live notifications; `/:slug/connections` lists a member's connections plus, for the owner, their incoming and outgoing requests. Posts gain a **connections-only** audience (see below). Legacy mutual follows were backfilled to accepted connections.
- **Blocking** (`Vutuv.Social.Block`): reachable wherever you decide to block someone — a quiet "Block" next to the profile footer's Report, a calm overflow menu in the direct-message thread (the moment unwanted contact usually arrives), and a "Block someone by @handle" form on `/blocks` itself (so the "block my ex" case needs no detour through their profile). All three run the same `Social.block_user/2`. Blocking severs follows + connection both ways (`Social.sever_between/2`), freezes the 1:1 conversation, and refuses every new interaction in **both** directions (follow, connect, message, reply, like, repost); third-party reposts of a blocked author also stay out of the blocker's feed. Reading is untouched (public stays public). The blocked party only ever sees the same generic refusals a decline/freeze produces. The private list at `/blocks` also unblocks; unblocking restores nothing (deliberately unlike a rejected moderation report) but thaws the conversation its own block froze, unless a reverse block or an active report severance still stands
- **Profile "view as" preview** (owner-only): on your own profile a slim "Ansehen als" switcher re-renders the page by the relationship tiers the app already names — `Sie` (your full view) / `Follower` (someone who follows you) / `Vernetzt` (a mutual connection) / `Öffentlich` (logged-out visitors and search engines). Each tier shows exactly what that relationship reveals: a **Follower** sees your *followers-only* posts; a **Vernetzt** connection also sees *connections-only* posts **and your private emails** (a connection is a mutual follow, and vutuv shows private emails to people you follow); **Öffentlich** sees public posts and the public email set only, with restricted posts gone. Owner chrome (Edit, the completion checklist, dashed add tiles, manage footers, the post author menus) disappears, and the rail follow controls render from the logged-out viewpoint so no control fires as you. Post visibility per tier is enforced **server-side** via `?view_as=follower|connection|public` and a simulated-relationship scope (`Vutuv.Posts.scope_visible_preview/2`), so a connections-only post can never leak into a Follower or public preview — private data never reaches a preview's HTML to be hidden client-side. Honored only for the owner (a stranger's `?view_as=` is ignored); the header's relationship controls show in their correct state (Vernetzen vs "✓ Vernetzt", Folge ich) but are inert (`pointer-events-none`).
- **Direct messages**: persisted 1:1 conversations (`Vutuv.Chat`) at `/messages`, with live delivery, typing indicators and online dots. Anyone validated can write to anyone, but the conversation lands directly only when the **recipient already follows the sender** — otherwise it is a **message request** the recipient accepts (explicitly or by replying) or declines; declining is silent (the sender cannot tell it from being ignored) and opening new requests is rate-limited. The shell badge counts conversations with unread messages, and a debounced email (one per conversation per unread burst, after 15 unread minutes) points the recipient back at the thread.
- **Posts + newsfeed**: Markdown posts (up to 20k chars) with images and tags. Everything post-related lives under `/:slug/posts`: the author archive (`/:slug/posts`, scopable to a year/month/day — `/:slug/posts/2026/06`), and permalinks keyed by the post's UUID v7: `/:slug/posts/:id` (non-canonical casing redirects to the lowercase URL). The feed at `/feed` is a LiveView: composer on top, pull-model timeline (own + followed authors' posts **and reposts**, with a "Reposted by X" line) with cursor "Load more", and a *"Show N new posts"* pill fed by `{:new_post, …}` / `{:new_repost, …}` broadcasts. The profile page and the archive show the author's timeline (posts + reposts). Audiences are **deny-based** (`Vutuv.Posts`): a post with no denials is public; denials exclude groups of the author's followees, single users, or wildcards (`non_connections`, `non_followers`, `non_followees`, `logged_out`, `everyone`) — the composer offers presets (public / followers / connections / only me) plus a custom "Hide from…" sheet with a person typeahead. The search page (`/search`) also finds words in **fully public** posts (Postgres FTS over a generated `search_tsv` column, `websearch_to_tsquery`, 'simple' config); any denial keeps a post out of search. Any denial also hides the post from logged-out visitors and noindexes it; a followers-only post shows a follow teaser and a connections-only post a connect teaser to denied readers, every other denial 404s. Deleting a group that posts deny is refused (it would silently widen audiences).
- **Likes, bookmarks, reposts**: every post card carries a live action bar (`VutuvWeb.PostLive.Actions`, one embedded LiveView per card via `live_render`), so the like/repost/bookmark counters tick in real time on the feed *and* on classic pages (permalink, profile, archive). Counters are counted live from the `post_likes` / `post_bookmarks` / `post_reposts` rows and broadcast as absolute values on the post topic (`"post:<id>"`). Likes and bookmarks work on any visible post **and on any member** — from a profile a logged-in visitor can like / bookmark another member (`Vutuv.Social`, tables `user_likes` / `user_bookmarks`), a private, silent save that needs no follow or connection and is refused only across a block. The private saved-items hub at `/likes` and `/bookmarks` lists both saved **posts and saved people**, each under a **Posts / People** sub-tab, with a search box (post body + author name; person name, `@handle`, headline) and a sort control (newest / oldest / name), offset "Load more", and entries that appear and disappear live across sessions. **Reposts** work on public posts only and distribute the post into the reposter's followers' feeds; while reposts exist the author cannot restrict the post's audience (the composer pins it to Public, `Vutuv.Posts.update_post/2` enforces it) but can always delete the post.
- **Replies (threads)**: a reply is a **normal post** (own permalink, audience, images, tags, likes/reposts/bookmarks, shows up in the replier's feed and profile) plus a `post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`). Replying works on **public** parents only (the reply button on restricted posts is disabled, like repost) and pins the parent's audience open like reposts do. Replies to replies are allowed; each card's banner names its direct parent. The permalink page lists the visible replies oldest-first, the action bar carries a live reply counter, and the parent's author gets a derived "replied to your post" notification (self-replies excluded). A reply **outlives its parent**: the banner (which names the account as `@handle`, never the clear name) degrades from "Replying to @handle" (post link) to "Reply to a now-deleted post by @handle" (profile link) to a nameless "Reply to a deleted post" once the account is gone too — no name is retained past account deletion.
- **Post images**: uploaded eagerly in the composer (so inline `![](…)` references work before submitting; abandoned uploads are swept after a day), up to 10 per post, 6 MB each (`jpg/png/webp`, plus `heic` when the libvips build can decode it — capability-detected via `priv/heic_probe.heic`). All served versions are AVIF (see **Images** below), EXIF-autorotated and **metadata-stripped** (no GPS leaks); the original keeps its metadata in the private `originals/` tree and is never served. Every image byte goes through the authorizing proxy `GET /post_images/:token/:version` (`VutuvWeb.PostImageController`), so a post's audience guards its images too — in production via nginx `X-Accel-Redirect` (see Deployment), in dev via `send_file`. Legacy `…/feed.webp` URLs in old post bodies keep resolving.
- **Moderation (family-friendly by design)**: any member can report a post, a private message or a whole profile (quiet "Report" affordances on every post card, message bubble and profile footer; categories: not family-friendly, bullying/harassment, spam, other). A report from a reporter in good standing **freezes the content instantly** (`frozen_at`) — it vanishes for everyone but the owner and admins, with no public tombstone — and opens a `Vutuv.Moderation.Case`. The owner is notified (in-app + email) and can settle it **without an admin** at `/moderation/cases/:id`: delete it, edit it (auto-unfreezes; a re-report then skips self-service) or dispute it ("my content is fine" — stays frozen, escalates). Silence for 72h escalates too (`Vutuv.Moderation.Sweeper`), so the admin queue at `/admin/moderation` only carries disputes, ignored cases, re-reports and profile cases. Admin rulings are one click: **uphold** (owner gets a strike: warning → one-week suspension → permanent deactivation; strikes expire after 12 months) or **reject** (unfreezes; rejections lower the reporter's trust, and reports marked *abusive* strike the **reporter** on the same ladder — reporting-as-a-weapon is treated as bullying). Reporters with a bad track record lose the instant freeze (their reports only flag for review), whole profiles freeze only on a **second** independent trusted report, and `/admin/moderation/reporters` shows every reporter's track record. Suspended/deactivated accounts cannot log in and disappear from feeds, profiles and search. House rules live at `/community`. **Reporting someone also separates the two accounts on the spot** (before any second report or admin ruling): connection and follows are removed and the 1:1 conversation is frozen for both sides; the report form warns a tied reporter up front (including that the separation de-facto reveals who reported), and after sending the reporter is told again (flash + a notification) that the pause works in both directions and is undone if admins find the report unfounded - a rejected case restores exactly what was cut (recorded in `moderation_severances`), an upheld one leaves the separation in place. Profile and message reports also capture a **full-page evidence screenshot** at report time (`Vutuv.Moderation.EvidenceScreenshot`: headless Chromium with a very tall window, trimmed by libvips; message threads render through the token-guarded `/moderation/evidence/:token` page), stored under the private `moderation_evidence/` tree and shown to admins via the authorizing `/admin/moderation/:id/evidence` route. Every case carries an **audit log** (`moderation_events`: reports, freezes, severances, owner self-service, escalations, rulings, strikes) rendered as the History timeline on the admin case page, and the urgent admin email names the profile, category and reporter's note instead of just a link.
- **Agent formats (markdown for agents)**: every public page is also served as **Markdown**, **plain text** (80 columns), **JSON** and **XML** under the same URL plus an extension — `/stefan.wintermeyer.md` / `.txt` / `.json` / `.xml`, the profile additionally as `.vcf` (vCard 3.0) — or via `Accept: text/markdown` / `text/plain` / `application/json` / `application/xml` content negotiation (the Cloudflare "markdown for agents" convention). Covered pages: profile, post permalinks, the post archive, follower/following lists, tag pages and the most-followed listing; `/llms.txt` documents the scheme. Labels default to English (the canonical, cache-safe rendering — the session locale is deliberately ignored); `?lang=de` opts into a translated rendering, and the profile's "Other formats" card links it for visitors browsing in German. All variants render the **anonymous public view** from one doc map per page (`VutuvWeb.AgentDocs.*Doc` — the single source of truth; a drift test fails when a page's HTML and its docs diverge). Documents carry `schema_version` + `generated_at`; responses carry `Content-Signal`, `Vary: Accept` and `x-markdown-tokens`. The signals render **two independent member choices** (`VutuvWeb.ContentPolicy`), both asked at sign-up and editable on the profile form: `noindex?` (search engines → `search=`, robots `noindex`) and `noai?` (AI agents/LLMs → `ai-train=`/`ai-input=`, robots `noai, noimageai`) — any combination is valid; pages that are noindexed page-level (profile sections, people lists, restricted posts) send every signal as `no`. Existing members were migrated as AI-opted-out (they were never asked) and can opt in on the edit form. The extension parsing lives in `VutuvWeb.Plug.AgentFormat` (endpoint; only the five known extensions are stripped, so dotted slugs keep working, and a `.md` URL that no controller answers 404s instead of serving HTML). **Agent readiness** (per specification.website): `/sitemap.xml` (chunked index over members/posts/tags, `Vutuv.Sitemap`), RSS 2.0 feeds with full post content (`/:slug/posts/feed.xml` per member, `/posts/feed.xml` site-wide, `VutuvWeb.Feeds`), robots.txt names the AI crawlers and declares draft `Content-Signal` directives from the one policy source (`VutuvWeb.ContentPolicy`, config `:ai_crawler_policy` — flips robots.txt and the response headers together), `Link` headers advertise llms.txt/sitemap/per-page alternates (`VutuvWeb.Plug.AgentLinks`), schema.org JSON-LD (Person on profiles, BlogPosting on permalinks, WebSite+SearchAction on the homepage — `VutuvWeb.JsonLd`, drift-tested against the doc builders), and `/.well-known/` serves agent-skills discovery (Cloudflare draft, digest-verified `SKILL.md`) plus `security.txt`
- **Link previews (Open Graph)**: every HTML page carries `og:*` + `twitter:card` tags derived in one chokepoint (`VutuvWeb.OpenGraph`, rendered by the root layout; the plain description meta shares the same derivation). Pages about a member preview their name, work info and avatar — served as a scraper-friendly square JPEG at `/:slug/avatar.jpg` (`VutuvWeb.AvatarController`; preview scrapers don't decode the site's AVIF), derived on the fly from the kept original, metadata-stripped. Public posts preview as articles with their first line, date and first image (`/post_images/<token>/og.jpg`, derived on the fly by the authorizing proxy, so audience changes keep guarding it); restricted posts and teasers never leak the body or an image. Everything else falls back to `/og-card.png` (`VutuvWeb.OgCard`): the white wordmark vector-rasterized onto the brand gradient, generated once per node (no font dependency).
- **Daily text ad** (`Vutuv.Ads`): one discreet, text-only ad per calendar day (Europe/Berlin via the fixed EU DST rule, no tz dependency), rendered between the top navigation and the content in the style of classic text ads, always labeled "Ad"/"Werbung". A visitor sees it at most **once per hour** (session-tracked, and only counted when the banner actually rendered), it hides itself after **two minutes** (app.js), and its **✕ dismisses ads for the rest of the day** (a day-stamped client cookie the plug honors). On unbooked days a short house ad sells the slot. Booking is online at `/ads` → `/ads/new` (logged-in only): pick a free day (one ad/day, unique index), enter the invoice address, ad text as Markdown (max 2048 chars, must be family-friendly, rendered through `VutuvWeb.Markdown`). 1.250 € net per day, payment by invoice: the booking mail (billing data + ad text) goes to the operator, who invoices manually; serving on the booked day is automatic. **Every ad is admin-approved before it runs** (`approved_at`; an unapproved ad never serves, the house ad fills its day): the review dashboard lives at `/admin/ads` (with a pending badge on the admin panel), the member sees the approval state of their bookings at `/ads/bookings`, and the earliest bookable day is **three days out** to leave room for the review. Bookings are accepted only inside the **booking window** (through the end of next month); the booking form shows it as month-grid calendars with free days as radio buttons and booked days struck through, and submits to a **preview step** that renders the ad through the real banner component (without its auto-hide/seen-marker hooks) before the binding confirm POST books it. `/ads` is a public page with agent-format siblings (`VutuvWeb.AgentDocs.AdsDoc`). The whole system sits behind a global switch (`config :vutuv, :ads_enabled`, read via `Vutuv.Ads.enabled?/0`), **off by default**: with it off no banner serves and the `/ads` flow plus the `/admin/ads` review dashboard 404, while `"ads"` stays a reserved username slug so the handle is kept free
- **Routes**: Verified routes (`~p"..."` sigils). Profiles live at the URL root, GitHub-style: `/:slug` is the profile and all per-user sub-pages hang off it (`/:slug/links`, `/:slug/followers`, `/:slug/following`, `/:slug/connections`, ...). The legacy `/users/:slug/...` URLs, `/sessions/new` and `/search_queries/...` 301 to their new homes (`/login`, `/logout`, `/search`). The user scope is the **last** in the router, so static routes always win; `Vutuv.Accounts.ReservedSlugs` keeps users from registering a slug that equals a route prefix. The old read-only `/api/1.0` JSON API was removed in favor of `/api/2.0`; only the session-aware vCard survived, at `/:slug/vcard`
- **Third-party API** (`/api/2.0`, `Vutuv.ApiAuth`): an authenticated REST/JSON API for scripts and third-party apps. Bearer tokens only (no session/CSRF; CORS wide open since no cookie authenticates): members mint **personal access tokens** at `/access_tokens` (scoped permissions like `profile:read`/`posts:write`, mandatory 30/90/365-day expiry, shown exactly once, SHA-256-hashed at rest, prefix `vutuv_pat_` for secret scanners; the new-token form is pre-filled — dated name, `profile:read`, 90 days — so the quickstart is one click) and revoke per token or all at once — every request verifies against the DB, so revocation, account moderation and (future) app suspension bite on the very next request. Reads go **through the authorizing member's eyes** (same visibility rules as the website, via the AgentDocs doc builders with a `viewer`); writes go through the same context functions as the UI, so blocking, moderation, audience locks, cooldowns and live broadcasts behave identically. Covered: profile (`PATCH /me`) + section CRUD (emails read-only — PIN-verified identities), follow/unfollow + the connection lifecycle + `GET …/relationship`, posts (compose with deny-based audiences, replies, like/bookmark/repost switches, the cursor-paginated `/feed` with signed opaque cursors), direct messages (request model included; a declined request stays indistinguishable from silence) and the notification feed. Per-token rate limit (5,000/h, `X-RateLimit-*` headers), RFC 9457 problem+json errors (422 with per-field messages), additive-only within `/api/2.0` (breaking changes mean a new version prefix). **OAuth 2** for real third-party apps (authorization code + mandatory PKCE S256, confidential clients, rotating refresh tokens with reuse-revocation, RFC 7009 revocation): developers register apps at `/developers/apps` (self-service, always owned by a vutuv account; `/admin/api_apps` is the suspend kill switch that fails every app token on its next request), members approve scopes on the `/oauth/authorize` consent screen and manage/withdraw access at `/connected_apps`. **Webhooks** (`Vutuv.Webhooks`): per-app subscriptions deliver signed thin event envelopes (HMAC-SHA256 in `X-Vutuv-Signature`, ids/slugs only, never content) for members who granted the matching scope; DB-backed queue with exponential backoff drained by `Vutuv.Webhooks.Deliverer`, auto-disable after sustained failure, test ping from the app page. Developer docs in English with curl examples at `/developers` (Markdown files in `priv/dev_docs/`, also served raw under `.md`): overview with a development/bug-reporting section, authentication, a task-recipe cookbook ("how do I post / send a DM?"), the data model (entities + visibility rules), the endpoint reference and webhooks — linked from the footer of every page. API profile responses carry the member's `noindex?`/`noai?` consent flags in-band (the public `.json`/`.md` siblings signal the same via `Content-Signal`/`X-Robots-Tag` headers)
- **Data export (GDPR)**: every member can download everything vutuv stores about them as one JSON file at `/:slug/export` (linked from the edit-profile sidebar). Strictly owner-only — it includes private data (all email addresses, direct messages, ad bookings). `Vutuv.Export` builds the document; a new per-user subsystem must add its section there (just like `Accounts.delete_user/1` must learn to delete it)
- **Email & phone number types**: every email address and phone number carries an owner-editable type label. Emails are **Work / Personal / Other** (`Vutuv.Accounts.Email.email_type`, default `Other`; offered on the registration form and the add-email form, the add-email choice carried through the two-step PIN confirmation via the session, editable later on the email edit form), phone numbers **Work / Cell / Home / Fax**. The label shows on the profile contact card and the management/show pages, is exported in the vCard (`EMAIL;TYPE=` / `TEL;TYPE=`) and the GDPR JSON, and rides in the agent-format docs — giving an email a type changed an email entry from a bare address string to a `{id, type, value}` map (matching phone numbers), a breaking change that bumped the agent-doc `schema_version`. On the profile contact card, German numbers are shown to **German viewers** in national format (`+49 261 9886803` → `0261 9886803`) while every `tel:` link keeps the canonical E.164 form, via `Vutuv.Phone` (the `ex_phone_number`/libphonenumber port); foreign numbers and non-German viewers see the stored value unchanged. On the way **in**, the changeset (`Vutuv.Phone.normalize/1`) parses a typed number against the default `DE` region, rejects anything libphonenumber does not recognise as a *valid* number (so only real numbers are saved), and stores the rest in canonical international form (`0261-123456` → `+49 261 123456`); a foreign number keeps its own country code. **Addresses** follow the same German-viewer rule (`Vutuv.Address`): a German viewer (`locale == "de"`) looking at a German address sees no redundant "Deutschland" line, while foreign addresses and non-German viewers keep the country; every address on the profile card also links out to **Google Maps, OpenStreetMap and Apple Maps** (the geocoding query keeps the country even when it is hidden on screen)
- **Username (@handle) changes**: members change their username at `/:slug/slugs/new`, linked from the edit-profile sidebar. Handles follow the Twitter username mechanism: letters, digits and underscores, 3 to 15 characters, stored lowercase, unique (`users.active_slug` carries the unique index; there is no slugs table), never a reserved route word; the form checks availability live while typing (`GET /:slug/slugs/availability`). Renaming frees the old handle immediately: no redirect, no reservation, anyone can claim it. Changes are limited to 4 per rolling 90 days (counted via the `slug_changes` ledger) and the form spells the quota out, including the next possible date once it is used up.
- **Authentication & sessions**: vutuv is **passwordless**. The baseline login is a two-step email-PIN flow (`/login` mails a 6-digit PIN, the second step verifies it; no password is ever stored). Returning members can also enrol one or more **passkeys** (WebAuthn / FIDO2 — Touch ID, Windows Hello, a security key) from the Account hub and sign in with one as an **alternative first factor**, skipping the email round-trip entirely (`Vutuv.Credentials`, the `wax_` library, table `user_credentials`; the browser ceremony is `assets/js/webauthn.js`, revealed only on supporting browsers). A passkey is enrolled only while logged in, so the email PIN stays the always-available fallback and the **only** way to bootstrap an account — a passkey is a faster *return* login, never the root of trust. Passkey verification funnels into the same `Accounts.login/2` exit as the PIN, so it gets the identical server-side per-device session row, new-device security email and live-socket wiring. Each login is a tracked **server-side session** (`Vutuv.Sessions`, table `user_sessions`, SHA-256-hashed token): members see where they are signed in, revoke a single device or all others, and add / remove passkeys at `/:slug/settings`; a noteworthy login (new device, suspicious location) mails a security alert
- **Pagination**: browse pages (followers, tags, the admin verification queue) use offset pagination — `Vutuv.Pages.paginate/3` on the query plus the `<.pager>` component for the numbered links; feed LiveViews (notifications) use cursor pagination instead — `Vutuv.Activity.notifications_page/2` behind a numbered "Load 50 of 80 more" button that appends to the stream. Displayed counts (badges, follower numbers) are compacted site-wide via `VutuvWeb.UI.compact_count/1`: exact up to 999, then 1K/80K/5M. The one exception is the landing-page member counter, which shows the **exact** total via `delimited_count/1` (see **Live member counter** below)
- **Forms**: `<.form>` component with `<.inputs_for>` for nested forms
- **Assets**: esbuild + Tailwind CSS v4; dark mode follows the system (`prefers-color-scheme`, no toggle) — legacy pages get their dark styles centrally from `assets/css/components.css`
- **HTTP server**: Bandit
- **Email**: Swoosh with compile-time EEx text templates; all mail built from `Emailer.base_email/0` and sent through one `Emailer.deliver/1` chokepoint that stamps the auto-generated robot headers and the bounce envelope sender (`Sender: bounces@vutuv.de` → SMTP MAIL FROM). **Notification mail is opt-out**: the unread-message nudge respects `users.notification_emails?`, carries RFC 8058 one-click unsubscribe headers and a tokenized footer link (`/unsubscribe/:token`, no login needed); transactional mail (PINs, moderation) cannot be opted out of. **Bounces feed back**: a failure DSN POSTed to `/webhooks/bounces` (by the production Postfix pipe, see Deployment) marks the address undeliverable, `deliver/1` then drops automatic mail to it; PIN mail still sends, and a successful login PIN through the address clears the mark
- **Images**: avatars, profile cover photos, URL screenshots and post images are stored on local disk and processed with [`image`](https://hex.pm/packages/image) (libvips); see `Vutuv.Avatar` / `Vutuv.Cover` / `Vutuv.Screenshot` / `Vutuv.PostImageStore`. **Every served version is AVIF**; the resolution, crop and quality of every version live in one module, `Vutuv.Uploads.Spec`, so a future format/compression change is a Spec edit plus one `mix vutuv.images.regenerate` run. Every uploaded **original** is kept verbatim (format + metadata) under the private `<UPLOADS_DIR_PREFIX>/originals/` tree (`Vutuv.Uploads.Originals`) as the source for re-deriving — it must **never** be served (no `Plug.Static` mount, no nginx alias; a regression test enforces this). Cover photos are uploaded via the Edit profile form and served from `<UPLOADS_DIR_PREFIX>/covers/` (nginx needs a `location /covers/` alias in production, mirroring `/avatars/`)
- **Fingerprinted avatar/cover filenames**: avatar and cover files are named `<handle>-<version>-<fingerprint>.avif` (e.g. `swintermeyer-medium-1a2b3c4d.avif`), where the fingerprint is `sha256(original)[0..11]`. The handle makes a downloaded file carry the username; the fingerprint makes the URL immutable, so it needs no `?v=` cache-buster and the **existing** nginx `alias` serves it directly (no rewrite). The fingerprint is stored in `users.avatar_fingerprint` / `cover_fingerprint`; a username change re-derives the files under the new handle. A row with no fingerprint has not been migrated yet and serves the legacy `avatar_<version>.avif?v=...` URL unchanged. The migration is **expand/contract**: the regenerator writes the new files and **keeps** the legacy ones (so the previous release and a rollback keep serving them); once the scheme is confirmed healthy in production, `mix vutuv.images.sweep_legacy` (`Vutuv.Release.sweep_legacy_images()`) deletes the legacy files — a deliberate, manual step, never part of the deploy
- **URL screenshots**: rendered by local headless Chromium, wrapped in a browser window frame (`Vutuv.BrowserFrame`); see `Vutuv.PageScreenshot`. Needs a `chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on `$PATH`)

### Context modules

Business logic is organized into Phoenix context modules under `lib/vutuv/`:

| Context | Schemas | Purpose |
|---|---|---|
| `Vutuv.Accounts` | User, Email, Slug, SearchTerm, LoginPin, Locale, Exonym | Registration, PIN-based authentication, user management |
| `Vutuv.Sessions` | UserSession | Server-side per-device sessions: signed-in-devices list, remote logout, new-device security email |
| `Vutuv.Credentials` | UserCredential | Passkeys (WebAuthn/FIDO2): enrolment + assertion verification for passkey login |
| `Vutuv.ApiAuth` | Token, App, Grant, AuthCode | API credentials: personal access tokens, OAuth 2 apps/grants/codes, scopes |
| `Vutuv.Webhooks` | Subscription, Delivery | Signed webhook deliveries to registered apps (queue, backoff, kill switch) |
| `Vutuv.Profiles` | Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience | User profile data |
| `Vutuv.Social` | Follow, Connection, Block, Group, Membership, UserLike, UserBookmark | Follows + mutual connections, blocking, groups, liking/bookmarking people |
| `Vutuv.Posts` | Post, PostDenial, PostImage, PostTag, PostLike, PostBookmark, PostRepost, PostReply | Posts, deny-model audiences, the feed, likes/bookmarks/reposts, replies/threads |
| `Vutuv.Tags` | Tag, UserTag, UserTagEndorsement | Tagging and endorsements |
| `Vutuv.Search` | SearchQuery, SearchQueryRequester, SearchQueryResult | Search functionality (people/tags; post full-text via `Vutuv.Posts.search_public/2`) |
| `Vutuv.Chat` | Conversation, Participant, Message | 1:1 direct messages, message requests, unread email notifier |
| `Vutuv.Moderation` | Case, Report, Strike | Reports, the content freezer, the strike ladder, reporter trust |
| `Vutuv.Notifications` | Emailer | Email notifications |
| `Vutuv.Ads` | Ad | The daily text ad: booking, billing record, serving |

## Running tests

```bash
mix test
```

## Deployment

> **v6 cutover (history):** the two non-routine one-time migrations, the
> **UUID v7 re-key** (every integer id became a UUID v7, image directories
> relabelled) and the **AVIF image pipeline**, **shipped to production on
> 2026-06-18**. The rollback soak was ended early the same day after
> verification: the `legacy_id_map` map table was dropped and a fresh v6 backup
> was taken (the pre-v6 backup is kept as a cold archive). One transitional bit
> is deliberately left in place: the `.webp` image fallback, still needed by a
> handful of old screenshots whose originals could not be re-encoded.

Deployment is automatic. Two GitHub Actions workflows drive it:

- **CI** (`.github/workflows/ci.yml`) runs `mix precommit` (compile with `--warnings-as-errors`, unused-deps, format, `credo --strict`, tests) on every pull request and on pushes to `main`.
- **Deploy** (`.github/workflows/deploy.yml`) runs on every push to `main`. So **merging or pushing anything to `main` ships it to production**; there is no separate deploy command.

The Deploy job runs on the self-hosted `vutuv3` runner (on bremen2) and executes `scripts/deploy.sh`, a **blue/green zero-downtime deploy**: it builds a `prod` release, runs migrations against `vutuv3_prod`, starts the release on the idle slot (`vutuv3@blue` on port 4003 / `vutuv3@green` on port 4005), waits until `GET /health` answers 200 with a live database connection, switches the nginx upstream (`/etc/nginx/snippets/vutuv3-upstream.conf`) with a graceful reload, drains for 30 s and stops the old slot. A failed build or boot leaves the old slot serving, untouched. A `deploy-production` concurrency group ensures two production deploys never overlap.

Because the old code briefly serves against the already-migrated database, **migrations must be backward-compatible**; a deploy that cannot be (such as the one-time UUID v7 re-key, which shipped on 2026-06-18 as a planned-downtime deploy) must be run deliberately, not pushed casually to `main`. The systemd slot template lives in `scripts/systemd/vutuv3@.service`.

### nginx for avatars, covers and screenshots (one-time setup)

These are **public** images served straight off disk. The vhost needs one
prefix-location `alias` per directory, all three pointing into
`<UPLOADS_DIR_PREFIX>` (`/srv/vutuv3` in prod). **All three are required** — a
missing block (it has happened with `/covers/`) means those images 404 even
though the file exists on disk and the app emits the right URL, because the
request falls through to the app, which does not serve them. Add to the vhost:

```nginx
location /avatars/ {
    alias /srv/vutuv3/avatars/;
    expires 30d;
    add_header Cache-Control "public";
}
location /covers/ {
    alias /srv/vutuv3/covers/;
    expires 30d;
    add_header Cache-Control "public";
}
location /screenshots/ {
    alias /srv/vutuv3/screenshots/;
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

The private originals tree (`/srv/vutuv3/originals/`) must **not** get any
`location`/`alias`: uploaded originals are never served.

### nginx for post images (one-time setup)

> **Note (forward-looking).** This snippet still names `/srv/legacy-vutuv`, but
> the current production host serves uploads from `/srv/vutuv3`
> (`UPLOADS_DIR_PREFIX`) and there are no post images in prod yet (its vhost has
> no `internal_post_images` location). When post images do ship, use
> `/srv/vutuv3` paths and an `\.avif$` pattern.

Post images are auth-proxied: the app checks the post's audience and answers with `X-Accel-Redirect`; nginx streams the file from an `internal` location (config `:post_image_serving` is `:accel_redirect` in prod). Unlike `/avatars/` and `/covers/` there must be **no public alias** for post images. Add to the vhost:

```nginx
# Post images: only reachable via X-Accel-Redirect from the app. The version
# pattern means originals (which keep their EXIF/GPS metadata) can never be
# served even if a path leaked. The "webp" alternative is transitional, for
# files `Vutuv.Release.regenerate_images()` has not converted yet — narrow
# the pattern to \.avif$ once a run reports nothing left to convert.
location ~ ^/internal_post_images/(?<token>[A-Za-z0-9_-]+)/(?<version>thumb|feed|large)\.(?<fmt>avif|webp)$ {
    internal;
    alias /srv/legacy-vutuv/post_images/$token/$version.$fmt;
}
```

Uploads run over the LiveView websocket (no `client_max_body_size` change needed for the 6 MB images unless the websocket location caps buffers unusually small).

### Email bounce handling (one-time setup)

All outbound mail uses `bounces@vutuv.de` as its SMTP envelope sender, so
every DSN lands in one mailbox. Pipe it into the app:

1. `install -m 755 scripts/postfix/vutuv-bounce /usr/local/bin/vutuv-bounce`
2. Generate a token, store it for both sides:
   - `/etc/vutuv/bounce-webhook-token` (chmod 600, read by the pipe script)
   - `BOUNCE_WEBHOOK_TOKEN=...` in the app env file (`/var/www/vutuv/shared/.env`)
3. Route the address into the pipe, e.g. via `/etc/aliases`:
   `bounces: "|/usr/local/bin/vutuv-bounce"` + `newaliases` (make sure
   `bounces@vutuv.de` resolves to local delivery in your Postfix setup).

Without `BOUNCE_WEBHOOK_TOKEN` the endpoint 404s and bounce handling is
simply off. Failure DSNs mark the address undeliverable (`emails.
undeliverable_at`, visible to the owner on their emails page); automatic
mail to it is dropped, PIN mail still sends, and a successful login PIN
through the address clears the mark.

## Maintenance / ops tasks

These tasks operate on the on-disk uploads under `<UPLOADS_DIR_PREFIX>/...` (see `config/runtime.exs`). They are meant to be run manually on the server.

- `mix vutuv.images.regenerate [--only avatars|covers|screenshots|post_images] [--dry-run]` re-derives every served image version (AVIF) from the kept originals per the current `Vutuv.Uploads.Spec`, relocating legacy public originals into the private `originals/` tree first. Idempotent; rows whose original is missing are skipped with a warning and left untouched. On the production release (no Mix) run `bin/vutuv eval "Vutuv.Release.regenerate_images()"` instead — safe while the app is serving traffic.
- `mix urls.create_screenshots` (re)renders URL screenshots. Needs the headless Chromium binary already described above (set `CHROMIUM_PATH` if it is not on `$PATH`).
