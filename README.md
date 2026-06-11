# vutuv

vutuv is a free, fast and open source social network service to host and share information about humans and organizations. It's hosted at https://vutuv.de.

We use [MIT License](https://mit-license.org/).

## Development Setup

vutuv is a [Phoenix Framework](https://www.phoenixframework.org/) 1.8 application. Install the following prerequisites using [mise](https://mise.jdx.dev/) (see `.tool-versions`):

- Erlang 28.5.0.1
- Elixir 1.20.0-otp-28
- [PostgreSQL](https://www.postgresql.org/) 17

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

Flag your account as admin:
```sql
UPDATE users SET administrator = true WHERE id = <user_id>;
```

Admin panel: http://localhost:4000/admin

A logged-in member without admin rights who opens `/admin` gets a 403 page that explains exactly this: admin rights are granted by the instance operator directly in the database (contact via Impressum).

## Architecture

- **Views**: mostly Phoenix 1.8 HTML modules with `embed_templates` (no `phoenix_view` dependency); **LiveView is being adopted incrementally** for the real-time parts (see below)
- **Real-time shell (LiveView)**: the app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with live unread badges) is embedded in the shared `app` layout via `live_render`, so the chrome and badges are live on every page. The **Messages** (`/messages`), **Notifications** (`/notifications`), **Feed** (`/feed`) and **Search** (`/search`) pages are LiveViews under a `live_session`; search is search-as-you-type (results from three letters on, exact and similar-sounding name matches clearly separated, `?q=` plus the filters keeps the URL shareable and a settled query is recorded once) with scope chips (all/people/skills/posts), an exact-only toggle and query operators parsed by `Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aka `first:`/`last:`), `@handle`, double quotes for exact, plus the combinable people filters `tag:`/`skill:` (has the skill) and `ort:`/`stadt:`/`city:` (address in that city) - e.g. `müller tag:php` or `müller ort:koblenz`. In-app updates flow over `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"`); online status and typing use `VutuvWeb.Presence`. The layout is split into `root.html.heex` (document shell) and `app.html.heex` (chrome), shared by classic controller pages and LiveViews. Notifications are real data **derived at read time** from the existing event tables (followers, endorsements, connections — accepted ones and pending incoming requests —, replies, likes; retroactively, no notifications table); each entry links to what it reports (the post, the requests page, the actor's profile). The only stored state is the `users.notifications_read_at` read marker behind the unread badge.
- **Live member counter**: the logged-out landing page shows the **exact** number of members and ticks it up in real time as people register. `Vutuv.Accounts.MemberCounter` keeps the total in a lock-free `:atomics` cell (ref in `:persistent_term`), so the per-render read (`count/0`) and the per-signup bump (`increment/0`, called from `Accounts.register_user/2`) are O(1) and never hit the database — a signup spike just races on one atomic add. A single owner GenServer seeds the cell from the DB at boot, re-reads the authoritative count on a slow timer (self-healing against deletions), and broadcasts the value only when it changed, so a burst of signups coalesces into at most one PubSub message per tick instead of a fan-out storm. The pill is the embedded `VutuvWeb.MemberCountLive` (rendered via `live_render`, like the shell).
- **Follow + connect (the social graph)**: two distinct relationships (`Vutuv.Social`). A **follow** (`Vutuv.Social.Follow`, table `follows`) is a one-directional subscription — follow anyone, no approval — and decides whose posts reach your `/feed`. A **connection** (`Vutuv.Social.Connection`) is mutual and consented: you request it, the other party accepts or declines (silently, with a re-request cooldown), and acceptance auto-creates a follow in **both** directions — which either side can then drop while staying connected, so "connected but not following" is a real state. The profile header carries both controls (`<.connect_control>` + `<.follow_button>`); requests/accepts push live notifications; `/:slug/connections` lists a member's connections plus, for the owner, their incoming and outgoing requests. Posts gain a **connections-only** audience (see below). Legacy mutual follows were backfilled to accepted connections.
- **Blocking** (`Vutuv.Social.Block`): a quiet "Block" next to the profile footer's Report. Blocking severs follows + connection both ways (`Social.sever_between/2`), freezes the 1:1 conversation, and refuses every new interaction in **both** directions (follow, connect, message, reply, like, repost); third-party reposts of a blocked author also stay out of the blocker's feed. Reading is untouched (public stays public). The blocked party only ever sees the same generic refusals a decline/freeze produces. The private list at `/blocks` unblocks; unblocking restores nothing (deliberately unlike a rejected moderation report) but thaws the conversation its own block froze, unless a reverse block or an active report severance still stands
- **Direct messages**: persisted 1:1 conversations (`Vutuv.Chat`) at `/messages`, with live delivery, typing indicators and online dots. Anyone validated can write to anyone, but the conversation lands directly only when the **recipient already follows the sender** — otherwise it is a **message request** the recipient accepts (explicitly or by replying) or declines; declining is silent (the sender cannot tell it from being ignored) and opening new requests is rate-limited. The shell badge counts conversations with unread messages, and a debounced email (one per conversation per unread burst, after 15 unread minutes) points the recipient back at the thread.
- **Posts + newsfeed**: Markdown posts (up to 20k chars) with images and tags. Everything post-related lives under `/:slug/posts`: the author archive (`/:slug/posts`, scopable to a year/month/day — `/:slug/posts/2026/06`), and permalinks keyed by the post's UUID v7: `/:slug/posts/:id` (non-canonical casing redirects to the lowercase URL). The feed at `/feed` is a LiveView: composer on top, pull-model timeline (own + followed authors' posts **and reposts**, with a "Reposted by X" line) with cursor "Load more", and a *"Show N new posts"* pill fed by `{:new_post, …}` / `{:new_repost, …}` broadcasts. The profile page and the archive show the author's timeline (posts + reposts). Audiences are **deny-based** (`Vutuv.Posts`): a post with no denials is public; denials exclude groups of the author's followees, single users, or wildcards (`non_connections`, `non_followers`, `non_followees`, `logged_out`, `everyone`) — the composer offers presets (public / followers / connections / only me) plus a custom "Hide from…" sheet with a person typeahead. The search page (`/search`) also finds words in **fully public** posts (Postgres FTS over a generated `search_tsv` column, `websearch_to_tsquery`, 'simple' config); any denial keeps a post out of search. Any denial also hides the post from logged-out visitors and noindexes it; a followers-only post shows a follow teaser and a connections-only post a connect teaser to denied readers, every other denial 404s. Deleting a group that posts deny is refused (it would silently widen audiences).
- **Likes, bookmarks, reposts**: every post card carries a live action bar (`VutuvWeb.PostLive.Actions`, one embedded LiveView per card via `live_render`), so the like/repost/bookmark counters tick in real time on the feed *and* on classic pages (permalink, profile, archive). Counters are counted live from the `post_likes` / `post_bookmarks` / `post_reposts` rows and broadcast as absolute values on the post topic (`"post:<id>"`). Likes and bookmarks work on any visible post; the private lists live at `/likes` and `/bookmarks` (tabs, cursor "Load more", entries appear and disappear live across sessions). **Reposts** work on public posts only and distribute the post into the reposter's followers' feeds; while reposts exist the author cannot restrict the post's audience (the composer pins it to Public, `Vutuv.Posts.update_post/2` enforces it) but can always delete the post.
- **Replies (threads)**: a reply is a **normal post** (own permalink, audience, images, tags, likes/reposts/bookmarks, shows up in the replier's feed and profile) plus a `post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`). Replying works on **public** parents only (the reply button on restricted posts is disabled, like repost) and pins the parent's audience open like reposts do. Replies to replies are allowed; each card's banner names its direct parent. The permalink page lists the visible replies oldest-first, the action bar carries a live reply counter, and the parent's author gets a derived "replied to your post" notification (self-replies excluded). A reply **outlives its parent**: the banner (which names the account as `@handle`, never the clear name) degrades from "Replying to @handle" (post link) to "Reply to a now-deleted post by @handle" (profile link) to a nameless "Reply to a deleted post" once the account is gone too — no name is retained past account deletion.
- **Post images**: uploaded eagerly in the composer (so inline `![](…)` references work before submitting; abandoned uploads are swept after a day), up to 10 per post, 6 MB each (`jpg/png/webp`, plus `heic` when the libvips build can decode it — capability-detected via `priv/heic_probe.heic`). All served versions are AVIF (see **Images** below), EXIF-autorotated and **metadata-stripped** (no GPS leaks); the original keeps its metadata in the private `originals/` tree and is never served. Every image byte goes through the authorizing proxy `GET /post_images/:token/:version` (`VutuvWeb.PostImageController`), so a post's audience guards its images too — in production via nginx `X-Accel-Redirect` (see Deployment), in dev via `send_file`. Legacy `…/feed.webp` URLs in old post bodies keep resolving.
- **Moderation (family-friendly by design)**: any member can report a post, a private message or a whole profile (quiet "Report" affordances on every post card, message bubble and profile footer; categories: not family-friendly, bullying/harassment, spam, other). A report from a reporter in good standing **freezes the content instantly** (`frozen_at`) — it vanishes for everyone but the owner and admins, with no public tombstone — and opens a `Vutuv.Moderation.Case`. The owner is notified (in-app + email) and can settle it **without an admin** at `/moderation/cases/:id`: delete it, edit it (auto-unfreezes; a re-report then skips self-service) or dispute it ("my content is fine" — stays frozen, escalates). Silence for 72h escalates too (`Vutuv.Moderation.Sweeper`), so the admin queue at `/admin/moderation` only carries disputes, ignored cases, re-reports and profile cases. Admin rulings are one click: **uphold** (owner gets a strike: warning → one-week suspension → permanent deactivation; strikes expire after 12 months) or **reject** (unfreezes; rejections lower the reporter's trust, and reports marked *abusive* strike the **reporter** on the same ladder — reporting-as-a-weapon is treated as bullying). Reporters with a bad track record lose the instant freeze (their reports only flag for review), whole profiles freeze only on a **second** independent trusted report, and `/admin/moderation/reporters` shows every reporter's track record. Suspended/deactivated accounts cannot log in and disappear from feeds, profiles and search. House rules live at `/community`. **Reporting someone also separates the two accounts on the spot** (before any second report or admin ruling): connection and follows are removed and the 1:1 conversation is frozen for both sides; the report form warns a tied reporter up front (including that the separation de-facto reveals who reported), and after sending the reporter is told again (flash + a notification) that the pause works in both directions and is undone if admins find the report unfounded - a rejected case restores exactly what was cut (recorded in `moderation_severances`), an upheld one leaves the separation in place. Profile and message reports also capture a **full-page evidence screenshot** at report time (`Vutuv.Moderation.EvidenceScreenshot`: headless Chromium with a very tall window, trimmed by libvips; message threads render through the token-guarded `/moderation/evidence/:token` page), stored under the private `moderation_evidence/` tree and shown to admins via the authorizing `/admin/moderation/:id/evidence` route. Every case carries an **audit log** (`moderation_events`: reports, freezes, severances, owner self-service, escalations, rulings, strikes) rendered as the History timeline on the admin case page, and the urgent admin email names the profile, category and reporter's note instead of just a link.
- **Agent formats (markdown for agents)**: every public page is also served as **Markdown**, **plain text** (80 columns) and **JSON** under the same URL plus an extension — `/stefan.wintermeyer.md` / `.txt` / `.json`, the profile additionally as `.vcf` (vCard 3.0) — or via `Accept: text/markdown` / `text/plain` / `application/json` content negotiation (the Cloudflare "markdown for agents" convention). Covered pages: profile, post permalinks, the post archive, follower/following lists, tag pages and the most-followed listing; `/llms.txt` documents the scheme. Labels default to English (the canonical, cache-safe rendering — the session locale is deliberately ignored); `?lang=de` opts into a translated rendering, and the profile's "Other formats" card links it for visitors browsing in German. All variants render the **anonymous public view** from one doc map per page (`VutuvWeb.AgentDocs.*Doc` — the single source of truth; a drift test fails when a page's HTML and its docs diverge). Documents carry `schema_version` + `generated_at`; responses carry `Content-Signal` (all `yes`, or all `no` when the member set `noindex?` or the page is noindexed), `Vary: Accept` and `x-markdown-tokens`. The extension parsing lives in `VutuvWeb.Plug.AgentFormat` (endpoint; only the four known extensions are stripped, so dotted slugs keep working, and a `.md` URL that no controller answers 404s instead of serving HTML)
- **Daily text ad** (`Vutuv.Ads`): one discreet, text-only ad per calendar day (Europe/Berlin via the fixed EU DST rule, no tz dependency), rendered between the top navigation and the content in the style of classic text ads, always labeled "Ad"/"Werbung". A visitor sees it at most **once per hour** (session-tracked, and only counted when the banner actually rendered), it hides itself after **two minutes** (app.js), and its **✕ dismisses ads for the rest of the day** (a day-stamped client cookie the plug honors). On unbooked days a short house ad sells the slot. Booking is online at `/ads` → `/ads/new` (logged-in only): pick a free day (one ad/day, unique index), enter the invoice address, ad text as Markdown (max 2048 chars, must be family-friendly, rendered through `VutuvWeb.Markdown`). 1.250 € net per day, payment by invoice: the booking mail (billing data + ad text) goes to the operator, who invoices manually; serving on the booked day is automatic. **Every ad is admin-approved before it runs** (`approved_at`; an unapproved ad never serves, the house ad fills its day): the review dashboard lives at `/admin/ads` (with a pending badge on the admin panel), the member sees the approval state of their bookings at `/ads/bookings`, and the earliest bookable day is **three days out** to leave room for the review. Bookings are accepted only inside the **booking window** (through the end of next month); the booking form shows it as month-grid calendars with free days as radio buttons and booked days struck through, and submits to a **preview step** that renders the ad through the real banner component (without its auto-hide/seen-marker hooks) before the binding confirm POST books it. `/ads` is a public page with agent-format siblings (`VutuvWeb.AgentDocs.AdsDoc`)
- **Routes**: Verified routes (`~p"..."` sigils). Profiles live at the URL root, GitHub-style: `/:slug` is the profile and all per-user sub-pages hang off it (`/:slug/links`, `/:slug/followers`, `/:slug/following`, `/:slug/connections`, ...). The legacy `/users/:slug/...` URLs, `/sessions/new` and `/search_queries/...` 301 to their new homes (`/login`, `/logout`, `/search`). The user scope is the **last** in the router, so static routes always win; `Vutuv.Accounts.ReservedSlugs` keeps users from registering a slug that equals a route prefix. The JSON API stays under `/api/1.0/users/:slug/...`
- **Data export (GDPR)**: every member can download everything vutuv stores about them as one JSON file at `/:slug/export` (linked from the edit-profile sidebar). Strictly owner-only — it includes private data (all email addresses, direct messages, ad bookings). `Vutuv.Export` builds the document; a new per-user subsystem must add its section there (just like `Accounts.delete_user/1` must learn to delete it)
- **Username (@handle) changes**: members change their username at `/:slug/slugs/new`, linked from the edit-profile sidebar. Handles follow the Twitter username mechanism: letters, digits and underscores, 3 to 15 characters, stored lowercase, unique (`users.active_slug` carries the unique index; there is no slugs table), never a reserved route word; the form checks availability live while typing (`GET /:slug/slugs/availability`). Renaming frees the old handle immediately: no redirect, no reservation, anyone can claim it. Changes are limited to 4 per rolling 90 days (counted via the `slug_changes` ledger) and the form spells the quota out, including the next possible date once it is used up.
- **Pagination**: browse pages (followers, tags, the admin verification queue) use offset pagination — `Vutuv.Pages.paginate/3` on the query plus the `<.pager>` component for the numbered links; feed LiveViews (notifications) use cursor pagination instead — `Vutuv.Activity.notifications_page/2` behind a numbered "Load 50 of 80 more" button that appends to the stream. Displayed counts (badges, follower numbers) are compacted site-wide via `VutuvWeb.UI.compact_count/1`: exact up to 999, then 1K/80K/5M. The one exception is the landing-page member counter, which shows the **exact** total via `delimited_count/1` (see **Live member counter** below)
- **Forms**: `<.form>` component with `<.inputs_for>` for nested forms
- **Assets**: esbuild + Tailwind CSS v4; dark mode follows the system (`prefers-color-scheme`, no toggle) — legacy pages get their dark styles centrally from `assets/css/components.css`
- **HTTP server**: Bandit
- **Email**: Swoosh with compile-time EEx text templates; all mail built from `Emailer.base_email/0` and sent through one `Emailer.deliver/1` chokepoint that stamps the auto-generated robot headers and the bounce envelope sender (`Sender: bounces@vutuv.de` → SMTP MAIL FROM). **Notification mail is opt-out**: the unread-message nudge respects `users.notification_emails?`, carries RFC 8058 one-click unsubscribe headers and a tokenized footer link (`/unsubscribe/:token`, no login needed); transactional mail (PINs, moderation) cannot be opted out of. **Bounces feed back**: a failure DSN POSTed to `/webhooks/bounces` (by the production Postfix pipe, see Deployment) marks the address undeliverable, `deliver/1` then drops automatic mail to it; PIN mail still sends, and a successful login PIN through the address clears the mark
- **Images**: avatars, profile cover photos, URL screenshots and post images are stored on local disk and processed with [`image`](https://hex.pm/packages/image) (libvips); see `Vutuv.Avatar` / `Vutuv.Cover` / `Vutuv.Screenshot` / `Vutuv.PostImageStore`. **Every served version is AVIF**; the resolution, crop and quality of every version live in one module, `Vutuv.Uploads.Spec`, so a future format/compression change is a Spec edit plus one `mix vutuv.images.regenerate` run. Every uploaded **original** is kept verbatim (format + metadata) under the private `<UPLOADS_DIR_PREFIX>/originals/` tree (`Vutuv.Uploads.Originals`) as the source for re-deriving — it must **never** be served (no `Plug.Static` mount, no nginx alias; a regression test enforces this). Cover photos are uploaded via the Edit profile form and served from `<UPLOADS_DIR_PREFIX>/covers/` (nginx needs a `location /covers/` alias in production, mirroring `/avatars/`)
- **URL screenshots**: rendered by local headless Chromium, wrapped in a browser window frame (`Vutuv.BrowserFrame`); see `Vutuv.PageScreenshot`. Needs a `chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on `$PATH`)

### Context modules

Business logic is organized into Phoenix context modules under `lib/vutuv/`:

| Context | Schemas | Purpose |
|---|---|---|
| `Vutuv.Accounts` | User, Email, Slug, SearchTerm, OAuthProvider, LoginPin, Locale, Exonym | Registration, PIN-based authentication, user management |
| `Vutuv.Profiles` | Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience | User profile data |
| `Vutuv.Social` | Follow, Connection, Block, Group, Membership | Follows + mutual connections, blocking, groups |
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

> **One-time cutover pending:** see [`DEPLOY_TODO.md`](DEPLOY_TODO.md) before
> the first production deploy of the AVIF image pipeline (nginx edit required).

Deployment is automatic. Two GitHub Actions workflows drive it:

- **CI** (`.github/workflows/ci.yml`) runs `mix precommit` (compile with `--warnings-as-errors`, unused-deps, format, `credo --strict`, tests) on every pull request and on pushes to `main`.
- **Deploy** (`.github/workflows/deploy.yml`) runs on every push to `main`. So **merging or pushing anything to `main` ships it to production**; there is no separate deploy command.

The Deploy job runs on the self-hosted `vutuv3` runner (on bremen2) and executes `scripts/deploy.sh`, a **blue/green zero-downtime deploy**: it builds a `prod` release, runs migrations against `vutuv3_prod`, starts the release on the idle slot (`vutuv3@blue` on port 4003 / `vutuv3@green` on port 4005), waits until `GET /health` answers 200 with a live database connection, switches the nginx upstream (`/etc/nginx/snippets/vutuv3-upstream.conf`) with a graceful reload, drains for 30 s and stops the old slot. A failed build or boot leaves the old slot serving, untouched. A `deploy-production` concurrency group ensures two production deploys never overlap.

Because the old code briefly serves against the already-migrated database, **migrations must be backward-compatible**; a deploy that cannot be (such as the one-time UUID v7 re-key prepared on the `version-6` branch, see `DEPLOY_TODO.md` there) is a planned-downtime deploy and must be run deliberately. The systemd slot template lives in `scripts/systemd/vutuv3@.service`.

### nginx for post images (one-time setup)

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

The private originals tree (`/srv/legacy-vutuv/originals/`) must **not** get any
nginx `location`/`alias`: uploaded originals are never served to anyone.

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
