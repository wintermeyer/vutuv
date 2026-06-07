# vutuv

vutuv is a free, fast and open source social network service to host and share information about humans and organizations. It's hosted at https://vutuv.de.

We use [MIT License](https://mit-license.org/).

## Development Setup

vutuv is a [Phoenix Framework](https://www.phoenixframework.org/) 1.8 application. Install the following prerequisites using [mise](https://mise.jdx.dev/) (see `.tool-versions`):

- Erlang 28.5.0.1
- Elixir 1.20.0-otp-28
- [PostgreSQL](https://www.postgresql.org/) 17

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

## Architecture

- **Views**: mostly Phoenix 1.8 HTML modules with `embed_templates` (no `phoenix_view` dependency); **LiveView is being adopted incrementally** for the real-time parts (see below)
- **Real-time shell (LiveView)**: the app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with live unread badges) is embedded in the shared `app` layout via `live_render`, so the chrome and badges are live on every page. The **Messages** (`/messages`), **Notifications** (`/notifications`) and **Feed** (`/feed`) pages are LiveViews under a `live_session`. In-app updates flow over `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"`); online status and typing use `VutuvWeb.Presence`. The layout is split into `root.html.heex` (document shell) and `app.html.heex` (chrome), shared by classic controller pages and LiveViews. Notifications are real data **derived at read time** from the existing event tables (followers, endorsements, mutual connections, replies — retroactively, no notifications table); the only stored state is the `users.notifications_read_at` read marker behind the unread badge. Messages still use dummy data; persistence is a follow-up.
- **Posts + newsfeed**: Markdown posts (up to 20k chars) with images and tags. Everything post-related lives under `/:slug/posts`: the author archive (`/:slug/posts`, scopable to a year/month/day — `/:slug/posts/2026/06`), and date-stamped blog-style permalinks: `/:slug/posts/2026/06/05/1` (UTC date + per-author-per-day counter, unpadded so there is no width limit; non-canonical URLs redirect). The feed at `/feed` is a LiveView: composer on top, pull-model timeline (own + followed authors' posts **and reposts**, with a "Reposted by X" line) with cursor "Load more", and a *"Show N new posts"* pill fed by `{:new_post, …}` / `{:new_repost, …}` broadcasts. The profile page and the archive show the author's timeline (posts + reposts). Audiences are **deny-based** (`Vutuv.Posts`): a post with no denials is public; denials exclude groups of the author's connections, single users, or wildcards (`non_followers`, `non_followees`, `logged_out`, `everyone`) — the composer offers presets (public / followers / following / only me) plus a custom "Hide from…" sheet with a person typeahead. Any denial also hides the post from logged-out visitors and noindexes it; a followers-only post shows a follow teaser to denied readers, every other denial 404s. Deleting a group that posts deny is refused (it would silently widen audiences).
- **Likes, bookmarks, reposts**: every post card carries a live action bar (`VutuvWeb.PostLive.Actions`, one embedded LiveView per card via `live_render`), so the like/repost/bookmark counters tick in real time on the feed *and* on classic pages (permalink, profile, archive). Counters are counted live from the `post_likes` / `post_bookmarks` / `post_reposts` rows and broadcast as absolute values on the post topic (`"post:<id>"`). Likes and bookmarks work on any visible post; the private lists live at `/likes` and `/bookmarks` (tabs, cursor "Load more", entries appear and disappear live across sessions). **Reposts** work on public posts only and distribute the post into the reposter's followers' feeds; while reposts exist the author cannot restrict the post's audience (the composer pins it to Public, `Vutuv.Posts.update_post/2` enforces it) but can always delete the post.
- **Replies (threads)**: a reply is a **normal post** (own permalink, audience, images, tags, likes/reposts/bookmarks, shows up in the replier's feed and profile) plus a `post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`). Replying works on **public** parents only (the reply button on restricted posts is disabled, like repost) and pins the parent's audience open like reposts do. Replies to replies are allowed; each card's banner names its direct parent. The permalink page lists the visible replies oldest-first, the action bar carries a live reply counter, and the parent's author gets a derived "replied to your post" notification (self-replies excluded). A reply **outlives its parent**: the banner (which names the account as `@handle`, never the clear name) degrades from "Replying to @handle" (post link) to "Reply to a now-deleted post by @handle" (profile link) to a nameless "Reply to a deleted post" once the account is gone too — no name is retained past account deletion.
- **Post images**: uploaded eagerly in the composer (so inline `![](…)` references work before submitting; abandoned uploads are swept after a day), up to 10 per post, 6 MB each (`jpg/png/webp`, plus `heic` when the libvips build can decode it — capability-detected via `priv/heic_probe.heic`). All served versions are AVIF (see **Images** below), EXIF-autorotated and **metadata-stripped** (no GPS leaks); the original keeps its metadata in the private `originals/` tree and is never served. Every image byte goes through the authorizing proxy `GET /post_images/:token/:version` (`VutuvWeb.PostImageController`), so a post's audience guards its images too — in production via nginx `X-Accel-Redirect` (see Deployment), in dev via `send_file`. Legacy `…/feed.webp` URLs in old post bodies keep resolving.
- **Routes**: Verified routes (`~p"..."` sigils). Profiles live at the URL root, GitHub-style: `/:slug` is the profile and all per-user sub-pages hang off it (`/:slug/links`, `/:slug/followers`, `/:slug/following`, ...). The legacy `/users/:slug/...` URLs, `/sessions/new` and `/search_queries/...` 301 to their new homes (`/login`, `/logout`, `/search`). The user scope is the **last** in the router, so static routes always win; `Vutuv.Accounts.ReservedSlugs` keeps users from registering a slug that equals a route prefix. The JSON API stays under `/api/1.0/users/:slug/...`
- **Pagination**: browse pages (followers, tags, the admin verification queue) use offset pagination — `Vutuv.Pages.paginate/3` on the query plus the `<.pager>` component for the numbered links; feed LiveViews (notifications) use cursor pagination instead — `Vutuv.Activity.notifications_page/2` behind a numbered "Load 50 of 80 more" button that appends to the stream. Displayed counts (badges, follower numbers, the member counter) are compacted site-wide via `VutuvWeb.UI.compact_count/1`: exact up to 999, then 1K/80K/5M
- **Forms**: `<.form>` component with `<.inputs_for>` for nested forms
- **Assets**: esbuild + Tailwind CSS v4; dark mode follows the system (`prefers-color-scheme`, no toggle) — legacy pages get their dark styles centrally from `assets/css/components.css`
- **HTTP server**: Bandit
- **Email**: Swoosh with compile-time EEx text templates; all mail built from `Emailer.base_email/0` and sent through one `Emailer.deliver/1` chokepoint that stamps the auto-generated robot headers
- **Images**: avatars, profile cover photos, URL screenshots and post images are stored on local disk and processed with [`image`](https://hex.pm/packages/image) (libvips); see `Vutuv.Avatar` / `Vutuv.Cover` / `Vutuv.Screenshot` / `Vutuv.PostImageStore`. **Every served version is AVIF**; the resolution, crop and quality of every version live in one module, `Vutuv.Uploads.Spec`, so a future format/compression change is a Spec edit plus one `mix vutuv.images.regenerate` run. Every uploaded **original** is kept verbatim (format + metadata) under the private `<UPLOADS_DIR_PREFIX>/originals/` tree (`Vutuv.Uploads.Originals`) as the source for re-deriving — it must **never** be served (no `Plug.Static` mount, no nginx alias; a regression test enforces this). Cover photos are uploaded via the Edit profile form and served from `<UPLOADS_DIR_PREFIX>/covers/` (nginx needs a `location /covers/` alias in production, mirroring `/avatars/`)
- **URL screenshots**: rendered by local headless Chromium, wrapped in a browser window frame (`Vutuv.BrowserFrame`); see `Vutuv.PageScreenshot`. Needs a `chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on `$PATH`)

### Context modules

Business logic is organized into Phoenix context modules under `lib/vutuv/`:

| Context | Schemas | Purpose |
|---|---|---|
| `Vutuv.Accounts` | User, Email, Slug, SearchTerm, OAuthProvider, LoginPin, Locale, Exonym | Registration, PIN-based authentication, user management |
| `Vutuv.Profiles` | Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience | User profile data |
| `Vutuv.Social` | Connection, Group, Membership | Following, groups |
| `Vutuv.Posts` | Post, PostDenial, PostImage, PostTag, PostLike, PostBookmark, PostRepost, PostReply | Posts, deny-model audiences, the feed, likes/bookmarks/reposts, replies/threads |
| `Vutuv.Tags` | Tag, UserTag, UserTagEndorsement | Tagging and endorsements |
| `Vutuv.Search` | SearchQuery, SearchQueryRequester, SearchQueryResult | Search functionality |
| `Vutuv.Notifications` | Emailer | Email notifications |

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

The Deploy job runs on the self-hosted `vutuv3` runner (on bremen2) and executes `scripts/deploy.sh`, which builds a `prod` release, runs migrations against `vutuv3_prod`, atomically flips the `current` symlink, and restarts the `vutuv3` systemd service. A `deploy-production` concurrency group ensures two production deploys never overlap. nginx is not touched by the script.

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

## Maintenance / ops tasks

These tasks operate on the on-disk uploads under `<UPLOADS_DIR_PREFIX>/...` (see `config/runtime.exs`). They are meant to be run manually on the server.

- `mix vutuv.images.regenerate [--only avatars|covers|screenshots|post_images] [--dry-run]` re-derives every served image version (AVIF) from the kept originals per the current `Vutuv.Uploads.Spec`, relocating legacy public originals into the private `originals/` tree first. Idempotent; rows whose original is missing are skipped with a warning and left untouched. On the production release (no Mix) run `bin/vutuv eval "Vutuv.Release.regenerate_images()"` instead — safe while the app is serving traffic.
- `mix urls.create_screenshots` (re)renders URL screenshots. Needs the headless Chromium binary already described above (set `CHROMIUM_PATH` if it is not on `$PATH`).
