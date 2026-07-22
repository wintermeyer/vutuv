# Running your own vutuv

vutuv is free, open-source software (MIT license): any organization or person can
run their own installation — on the public internet or inside an intranet.
This document is the operator's manual: how to install, configure, and run it.

**We would love to hear about your installation!** If you run vutuv somewhere,
tell us about it — and report anything that made installing harder than it
should be — via a [GitHub issue](https://github.com/wintermeyer/vutuv/issues/new).

Related documents: [README](../README.md) (overview) ·
[DEVELOPERS](DEVELOPERS.md) (codebase, architecture, dev setup) ·
[CONTRIBUTING](../CONTRIBUTING.md).

## What you need

- A Linux server (the reference installation runs Debian; anything that runs
  Erlang works). One host is enough to start (vutuv.de has run on a single
  machine so far); very large installations can spread across multiple nodes,
  which Elixir/BEAM supports natively.
- **PostgreSQL 17** (older 14+ versions likely work, 17 is what is tested).
- **Erlang and Elixir** to build the release — install via
  [mise](https://mise.jdx.dev/) (`mise install` reads the pinned versions from
  `.tool-versions`).
- **libvips** for image processing (`apt-get install libvips-dev`).
- **Chromium** (optional) — only for URL screenshots and moderation evidence
  screenshots. Without it those features quietly do nothing.
- **poppler-utils** (optional, `apt-get install poppler-utils`) — renders the
  first page of PDF proof documents that members can attach to their
  certificates & licenses. Without `pdftoppm` on `$PATH`, PDF uploads are
  refused with a clear message ("please upload an image instead"); image
  proofs keep working.
- An **SMTP relay** vutuv can send email through. Email is not optional:
  login works via emailed PINs (vutuv is passwordless).
- **nginx** (or another reverse proxy) in front of the app. Optional for a
  first test, recommended for real use.

No Node.js is required (esbuild and Tailwind are Elixir deps), and there are
no external runtime services beyond PostgreSQL and SMTP.

## Build a release

```bash
git clone https://github.com/wintermeyer/vutuv.git
cd vutuv
mise install
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The self-contained release lands in `_build/prod/rel/vutuv/` — copy it to
where you want to run it (it must be built on the same OS/architecture).

## Database

Create a database and a user for it, e.g.:

```sql
CREATE USER vutuv WITH PASSWORD '...';
CREATE DATABASE vutuv3_prod OWNER vutuv;
```

Migrations run from the release (also used for every later upgrade):

```bash
bin/vutuv eval "Vutuv.Release.migrate()"
```

## Configuration

All runtime configuration comes from environment variables, read at boot by
`config/runtime.exs`. The recommended setup is a `chmod 600` EnvironmentFile
loaded by systemd (see below).

Two variables are **required** — the release refuses to boot without them:

| Variable | Purpose |
|---|---|
| `DB_PASS` | PostgreSQL password |
| `SECRET_KEY_BASE` | session/cookie signing — generate with `mix phx.gen.secret` |

Everything else has a default (the vutuv.de production value):

| Variable | Default | Purpose |
|---|---|---|
| `PHX_HOST` | `vutuv.de` | **Set this.** The public host name; every generated URL uses it |
| `PHX_SCHEME` | `https` | `http` for a TLS-less intranet installation |
| `PHX_URL_PORT` | `443`/`80` | The public port, if not the scheme default |
| `PORT` | `4003` | Local port the app listens on (loopback; nginx proxies to it) |
| `CHECK_ORIGINS` | – | Extra allowed websocket origins, comma-separated (host + `www.` twin are always allowed) |
| `DB_USER` | `vutuv` | PostgreSQL user |
| `DB_NAME` | `vutuv3_prod` | PostgreSQL database |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host |
| `POOL_SIZE` | `10` | DB connection pool |
| `UPLOADS_DIR_PREFIX` | `/srv/legacy-vutuv` | **Set this.** Root directory for uploaded images (avatars, covers, screenshots, post images, private originals) |
| `CHROMIUM_PATH` | – | Chromium binary, if not on `$PATH` |
| `SMTP_RELAY` | `127.0.0.1` | SMTP server |
| `SMTP_PORT` | `25` | SMTP port |
| `SMTP_USERNAME` | – | SMTP auth (empty = no auth) |
| `SMTP_PASSWORD` | – | SMTP auth |
| `SMTP_TLS` | `never` | STARTTLS: `never` / `if_available` / `always` |
| `SMTP_SSL` | `false` | `true` for implicit TLS (usually port 465) |
| `NEWSLETTER_SEND_TIMEOUT_SECONDS` | `60` | Wall-clock ceiling on a single newsletter send. gen_smtp's per-response read timeout is a fixed 20 minutes, so a black-holing relay could otherwise freeze a broadcast long enough to look stuck and be double-sent; a timed-out send is logged as an error and the loop moves on. Raise it only for a legitimately slow smarthost, and keep it well under five minutes |
| `MAILER_FROM_NAME` | `vutuv` | Display name of the From on every email |
| `MAILER_FROM_ADDRESS` | `no-reply@vutuv.de` | **Set this.** From address on every email |
| `BOUNCE_ADDRESS` | `bounces@vutuv.de` | **Set this**, to a mailbox that really accepts mail — bounces (DSNs) are addressed to it, and the default is *not* a live account. SMTP envelope sender; vutuv.de sets `sw@vutuv.de` |
| `OPERATOR_NAME` | `Wintermeyer Consulting` | **Set this.** Your name: site/email footer credit and operator-notice recipient name |
| `OPERATOR_EMAIL` | `sw@wintermeyer-consulting.de` | **Set this.** Receives the daily report, ad bookings and account-deletion records; also the `security.txt` contact |
| `OPERATOR_URL` | `https://wintermeyer-consulting.de` | **Set this.** Linked from the site/email footer |
| `OPERATOR_ADDRESS` | (vutuv.de's) | **Set this.** One-line postal address in every email footer |
| `APPEAL_REPLY_TO` | (vutuv.de's) | Reply-To on the account-deactivation (strike 3) email |
| `BOUNCE_WEBHOOK_TOKEN` | – | Bearer token for `POST /webhooks/bounces`; unset = bounce handling off |
| `MAIL_LOG_PATH` | `/var/log/mail.log` | Postfix log the bounce watcher tails; `""` = watcher off |
| `FEDIVERSE_ENABLED` | `true` | `false` turns follow-only ActivityPub federation off entirely (endpoints 404, nothing is delivered) — set it on intranet installations |
| `FETCH_BOOK_METADATA` | `true` | `false` turns the catalogue lookups behind post **book reviews** off (the composer's ISBN → title/author/year prefill, the cover image, page count and publisher from Open Library, and an audiobook's running time). The review feature itself keeps working — members type the fields by hand and the card renders without a cover or those details. Set it on installations that must not call out (intranets) |
| `DNB_SRU_URL` | `https://services.dnb.de/sru/dnb` | Where an **audiobook's running time** is looked up by ISBN: an SRU endpoint answering MARC21-xml (the Deutsche Nationalbibliothek by default — Open Library records no durations). Point it at another catalogue's SRU endpoint, or set it **empty** (`DNB_SRU_URL=`) to switch that one lookup off while the rest of the book metadata keeps working |
| `AMAZON_DOMAIN` | `www.amazon.de` | The store a book review card's shop link points at (`https://<domain>/dp/<isbn10>`). Set your regional store (`www.amazon.com`, …) — or an **empty** value (`AMAZON_DOMAIN=`) to remove the shop link entirely |
| `AMAZON_AFFILIATE_TAG` | – | Optional Amazon affiliate tag appended to book review shop links as `?tag=` |
| `AUDIBLE_DOMAIN` | `www.audible.de` | The Audible store an **audiobook** review card links the "Hörbuch"/"Audiobook" word to (a title search, since Audible keys by its own ASIN, not the print ISBN). Set your regional store (`www.audible.com`, …) — or an **empty** value (`AUDIBLE_DOMAIN=`) to keep the word plain text |
| `VERIFY_ORGANIZATION_DOMAINS` | `true` | `false` disables the verified-organization-page domain proof (the DNS TXT and well-known-file checks and their periodic re-check) — no new organization page can be verified, existing ones keep working. Set it on installations that must not make outbound DNS/HTTP calls. A newly verified organization sends an operator notice to `OPERATOR_EMAIL` |
| `VERIFY_USER_LINKS` | `true` | `false` disables verified personal-webpage links (a member proving a profile link is their own page via a rel=me back-link, or the same DNS TXT / well-known-file domain proof, plus their periodic re-check) — no new link can be verified, existing marks keep working. Set it on installations that must not make outbound DNS/HTTP calls |
| `GITHUB_API_TOKEN` | – | Optional token for the profile code-stats fetches (GitHub allows 60 unauthenticated requests/hour per IP; a token raises that to 5,000). A [fine-grained PAT](https://github.com/settings/personal-access-tokens) with **no** scopes/permissions is enough — the fetches read public data only. Can be added (or rotated) at any time; without it everything still works, the 7-day snapshot cache is sized for the unauthenticated limit |
| `MAIL_LOG_POLL_MS` | `5000` | Bounce watcher poll interval |
| `INVITATION_DAILY_CAP` | `50` | Most invitations a single member may send per day (abuse guard on outbound invite email) |
| `JOB_RUNTIME_DAYS` | `90` | How long a published job posting stays live before it auto-expires. Flat, no renewals — a still-open role gets a fresh posting |
| `JOBS_MAX_PER_MEMBER` | `3` | Most concurrently-published job postings for one member (anti-abuse) |
| `JOBS_MAX_PER_ORG` | `10` | Most concurrently-published job postings for one organization |
| `COLD_OUTREACH_LIMIT` | `20` | Anti-spam cap on how many new message *requests* one member may open to strangers (members who don't already follow them) within the window. Replying to an accepted thread never counts. A member over the cap gets a friendly "try again later"; admins see the counter on a poster in the `/admin/jobs` detail drawer |
| `COLD_OUTREACH_WINDOW_HOURS` | `24` | The window, in hours, over which `COLD_OUTREACH_LIMIT` is measured |
| `SAVED_SEARCHES_MAX_PER_MEMBER` | `10` | Most saved searches (with e-mail alerts) one member may store (anti-abuse). A member at the cap is asked to delete one first |
| `GEO_COUNTRIES` | `DE,AT,CH` | Comma-separated ISO 3166-1 alpha-2 codes whose bundled GeoNames postal data is loaded for offline zip → coordinate resolution on job postings. To add a country, drop its GeoNames zip export (`download.geonames.org/export/zip/<CC>.zip` → extracted `<CC>.txt`, optionally gzipped to `<CC>.txt.gz`) into `priv/geo/` and add the code here. Fully offline — no outbound calls |
| `IMAGE_MODERATION_ENABLED` | `true` | `false` turns AI image moderation off (images publish immediately, as before the feature). While enabled, **every** image — avatars, covers, post / job-posting / organization images and the automatic link screenshots — waits invisible to everyone but its owner until a local Ollama vision model approves it; an unsafe image is deleted on the spot and the owner notified. Fail-closed: with Ollama unreachable, new images queue up and are scanned automatically once it is back — nothing is ever auto-approved. Set `false` only on installations without Ollama |
| `OLLAMA_URL` | `http://localhost:11434` | Base URL of the Ollama instance the image scan talks to. May be a **comma-separated priority list** (`http://gpu-box:11434,http://localhost:11434`): every instance but the last is tried with a 30 s budget and skipped on any failure, the last one is the patient fallback (120 s, covers a CPU cold load). Verdicts are identical either way — the list only buys speed |
| `OLLAMA_VISION_MODEL` | `qwen3-vl:8b` | The vision model used for the safety verdict. Pull it once (`ollama pull qwen3-vl:8b`); any Ollama vision model works (`qwen3-vl:4b` halves the load on CPU-only servers) |
| `DEFAULT_COUNTRY` | `DE` | ISO 3166-1 alpha-2 code that preselects country inputs (job postings, organization pages) |

The defaults marked **Set this** are vutuv.de's operator identity — a fresh
installation should override all of them on day one, or your daily reports
will try to reach vutuv.de's operator.

A few rarely-changed switches are compile-time settings in
`config/config.exs` / `config/prod.exs` (edit before `mix release`):
`:ads_enabled` (the daily text-ad system, off by default),
`:ai_crawler_policy` (`:permissive` or `:block_training` — drives robots.txt
and the Content-Signal headers), `:fetch_gravatar`, `:fetch_mastodon_posts`,
`:fetch_bluesky_posts`, `:fetch_code_stats` (the profile "Code" card's
GitHub/GitLab/Codeberg statistics), `:generate_screenshots` (profile link
previews **and** the auto-screenshot for single-link posts — admins watch the
capture queue and browse the gallery at `/admin/screenshots`), and
`:serve_uploads_locally` (see nginx below).

## systemd

A template unit for the reference installation lives in
[`scripts/systemd/vutuv3@.service`](../scripts/systemd/vutuv3@.service)
(vutuv.de runs two of them for blue/green deploys). A minimal single-slot
unit:

```ini
[Unit]
Description=vutuv
After=network.target postgresql.service

[Service]
User=vutuv
EnvironmentFile=/srv/vutuv/shared/.env
ExecStart=/srv/vutuv/current/bin/vutuv start
ExecStop=/srv/vutuv/current/bin/vutuv stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## nginx

The app listens on the loopback (`PORT`); nginx terminates TLS and proxies
everything to it. LiveView needs websocket upgrades:

```nginx
server {
    server_name example.com;

    location / {
        proxy_pass http://127.0.0.1:4003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    # LinkedIn-import uploads may be up to 50 MB (the app enforces its own caps).
    client_max_body_size 64m;
}
```

### Uploaded images

Avatars, cover photos and URL screenshots are **public** images served
straight off disk. Give the vhost one prefix-location `alias` per directory,
all three pointing into `UPLOADS_DIR_PREFIX`. **All three are required** — a
missing block means those images 404 even though the file exists on disk,
because the request falls through to the app, which does not serve them:

```nginx
location /avatars/ {
    alias /srv/vutuv/uploads/avatars/;
    expires 30d;
    add_header Cache-Control "public";
}
location /covers/ {
    alias /srv/vutuv/uploads/covers/;
    expires 30d;
    add_header Cache-Control "public";
}
location /screenshots/ {
    alias /srv/vutuv/uploads/screenshots/;
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

The private `originals/` tree under `UPLOADS_DIR_PREFIX` must **not** get any
`location`/`alias`: uploaded originals (with their EXIF/GPS metadata) are
never served, by design.

**Post images need no nginx setup**: they are audience-guarded, so the app
authorizes and serves them itself (`send_file`).

Running without nginx aliases is possible: set
`config :vutuv, :serve_uploads_locally, true` **and**
`config :vutuv, :uploads_dir_prefix, "/your/uploads"` in `config/prod.exs`
before building (both are compile-time in this mode), and the app serves
those directories itself.

## First steps after installation

1. **Check email works.** Register an account on your installation — the
   confirmation PIN must arrive. Nothing else works until SMTP does.
2. **Make yourself admin:**
   `bin/vutuv eval 'Vutuv.Release.promote_admin("your-handle")'`
   (or `mix vutuv.admin.promote your-handle` in a source checkout). The admin
   panel appears in your account menu, at `/admin`.
3. **Write your legal pages** at `/admin/legal` — Impressum,
   Datenschutzerklärung and Nutzungsbedingungen. A fresh installation shows a
   neutral "not published yet" placeholder on those pages until you do. If you
   operate in Germany, publishing an Impressum and a privacy policy is a legal
   requirement, and the texts must name **you**, not vutuv.de's operator.
   The body is Markdown; vutuv.de's own texts can serve as a structural
   reference (`priv/repo/seed_data/legal/`), but the legal content is your
   responsibility.
4. **Review the operator variables** (`OPERATOR_*`, `MAILER_FROM_ADDRESS`,
   `BOUNCE_ADDRESS`) so system mail carries your identity, not vutuv.de's.

## Intranet installations

vutuv runs fine without internet access:

- Set `PHX_SCHEME=http` if the intranet has no TLS (and `PHX_HOST` to the
  internal host name). With TLS, nothing special is needed.
- Set `FEDIVERSE_ENABLED=false`: follow-only ActivityPub federation delivers
  posts to remote servers and fetches remote actor documents — pointless and
  noisy without internet access.
- Consider `VERIFY_ORGANIZATION_DOMAINS=false`: the verified-organization-page domain
  proof (DNS TXT + well-known file) needs to reach the domain being verified.
  On an intranet the DNS TXT method still works against an internal resolver,
  but the well-known fetch is blocked by the SSRF guard for internal hosts; set
  the flag to `false` to hide the feature entirely if organization pages are not
  wanted.
- Consider `VERIFY_USER_LINKS=false`: verified personal-webpage links (rel=me
  back-link, DNS TXT or well-known file) reach out to the member's page the same
  way, with the same SSRF guard against internal hosts. Set the flag to `false`
  to hide the feature if link verification is not wanted on the installation.
- Turn off the features that call out to the internet (compile-time flags in
  `config/config.exs`): `:fetch_gravatar` (avatar lookup at registration),
  `:fetch_mastodon_posts` / `:fetch_bluesky_posts` (the social-feed card on
  profiles), `:fetch_code_stats` (the profile "Code" card's GitHub/GitLab/
  Codeberg statistics — off, the accounts stay plain links), and
  `:generate_screenshots` (profile link-preview screenshots **and** the
  auto-screenshot for single-link posts — these fetch the linked page and run
  headless Chromium).
- Set `FETCH_BOOK_METADATA=false`: the book-review ISBN lookup, the cover
  fetch and the page-count/publisher lookup call Open Library, and an
  audiobook's running time is read from a library catalogue (`DNB_SRU_URL`).
  Book and film reviews keep working — the fields are typed by hand and the
  card renders without a cover and without those details.
- AI image moderation works **fully offline** — Ollama is local inference, no
  cloud involved. Install Ollama on the server, pull the vision model once
  while you still have internet access (`ollama pull qwen3-vl:8b`), and keep
  `IMAGE_MODERATION_ENABLED=true`. Only an installation without Ollama should
  set it to `false` (images then publish unmoderated, as before the feature).
- The map links on profile addresses (Google/OSM/Apple) are plain link-outs
  rendered in the visitor's browser; they simply won't resolve offline.
- Job postings need no configuration to work offline: their zip → coordinate
  resolution uses a bundled GeoNames postal dataset (`priv/geo/`), entirely
  offline with no outbound call. Add your intranet's country with
  `GEO_COUNTRIES` if it is not one of the shipped `DE`/`AT`/`CH`.
- Search engines and AI crawlers are irrelevant on an intranet; the
  robots.txt / Content-Signal machinery does no outbound calls either way.

## Email deliverability (optional)

vutuv can detect hard bounces and stop mailing dead addresses: a watcher
tails the local Postfix log (`MAIL_LOG_PATH`), or an external detector can
POST to `/webhooks/bounces` (guarded by `BOUNCE_WEBHOOK_TOKEN`). Without
either, bounce handling is simply off and nothing else breaks. The full
design, DSN taxonomy and a new-server runbook:
[`production-email-and-bounces.md`](production-email-and-bounces.md).

## Backups

Two things hold all state:

1. The PostgreSQL database (`pg_dump`).
2. The uploads directory (`UPLOADS_DIR_PREFIX`) — including the private
   `originals/` tree, from which every served image can be re-derived.

## Upgrades

```bash
git pull
MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release
bin/vutuv eval "Vutuv.Release.migrate()"   # then restart the service
```

Migrations are kept backward-compatible for one release (vutuv.de deploys
blue/green with zero downtime — see [DEVELOPERS](DEVELOPERS.md)), so a simple
stop → migrate → start on a single server is always safe.

## Maintenance tasks

Run on the server, against the release:

- `bin/vutuv eval "Vutuv.Release.regenerate_images()"` — re-derives every
  served image version (AVIF) from the kept originals per the current
  `Vutuv.Uploads.Spec`. Idempotent; safe while the app serves traffic.
- `bin/vutuv eval "Vutuv.Release.refresh_review_covers()"` — re-fetches every
  book-review cover from Open Library, and with it the page count, publisher
  and audiobook running time (the backfill for reviews written before those
  were shown). Book covers are the one image kind
  vutuv keeps no original of (see "Book covers" below), so `regenerate_images`
  cannot re-derive them; this is their equivalent after an upgrade that
  changes the cover size. Needs outbound network and `FETCH_BOOK_METADATA=true`,
  and paces itself (3s per cover) to stay inside Open Library's rate limit.
- `bin/vutuv eval 'Vutuv.Release.promote_admin("handle-or-email")'` — grants
  admin rights.

(In a source checkout the same exist as `mix vutuv.images.regenerate` /
`mix vutuv.review_covers.refresh` / `mix vutuv.admin.promote`; URL screenshots
can be re-rendered with `mix urls.create_screenshots`.)

## Book covers on review posts

With `FETCH_BOOK_METADATA=true` (the default) a book review's cover is
downloaded once from Open Library by ISBN and stored on your server, then
served from there — never hotlinked, so no reader's IP reaches a third party.
Worth knowing as an operator:

- **The image rights do not come with it.** Open Library passes the covers
  through and states plainly that it asserts no rights over them and that
  "there may be existing rights issues"; the artwork belongs to publishers.
  vutuv treats a cover as a **quotation** beside a review (§ 51 UrhG in
  Germany, comparable rules elsewhere) and is built accordingly: it stores
  only the one small derived version it displays (max 320px, no
  full-resolution original), shows it only attached to a review post, credits
  the source under the cover with a link to the book's Open Library page, and
  serves every cover with `X-Robots-Tag: noindex, noimageindex` so it stays
  out of image search.
- **Removal is instant.** An admin rejecting the image in
  `/admin/moderation` deletes the stored files; deleting the post does too.
  Keep a contact address reachable (`OPERATOR_EMAIL`, your imprint) so a
  rights holder can ask.
- **Your call, your risk.** Whether that quotation argument holds in your
  jurisdiction is your decision as the operator, not vutuv's. If you would
  rather not host third-party covers at all, set `FETCH_BOOK_METADATA=false`:
  reviews keep working and the card renders a neutral 📖/🎬 tile instead.

Note: `bin/vutuv eval` is the supported console entry point; `rpc`/`remote`
need distribution, which the reference setup disables.

## Preference defaults

Some behaviour is a **member preference** with an installation-wide default:
how many lines a post shows in the feed before "Read more" (desktop and
mobile separately), whether post text hyphenates, which map services appear
on addresses and which one opens first. Members tune these on their own
settings pages; you decide what everyone gets **until** they do.

- **`/admin` → Preference defaults** (`/admin/preferences`): change the
  default for the whole installation at any time. It applies immediately to
  every member who has not set an own value — and to logged-out visitors.
  Each field notes the shipped default and how many members have customized
  it (those members are unaffected). Saving a value equal to the shipped
  default simply removes your override.
- **Per-member overrides** (member browser `/admin/users` → the row's
  **Preferences** button): set or clear one member's values for support, e.g.
  to reproduce a display complaint. Blanking a field puts the member back on
  the installation default. You are editing the member's own settings — they
  see and can change the same values on their settings pages, where a "Reset
  to the site defaults" link does the same clearing.

No configuration file or restart is involved; the defaults live in the
database and every node picks changes up immediately.

## Honor tags

Besides the tags members give themselves, an admin can define **honor**
tags: badges that only admins grant, e.g. `vutuv_developer` for your
core team. Members can neither add nor remove them, and they are not endorsable.

From the admin panel (`/admin` → Tags):

1. Create the tag (or open an existing one), then **Edit** it and tick
   **Honor**.
2. On the tag's page, use **Add a member (by @handle or email)** to grant it, and
   the per-row **Remove** to take it back. The page lists everyone who holds it.

The badge shows on the member's profile (and its `.md`/`.json`/… siblings) with a
small "honor tag" marker. Reserve honor for **new** tag names: flipping a
tag that members already hold makes them keep it but blocks them from removing it
themselves.

## Moderation & spam

Members report posts, messages and whole profiles from the quiet "Report"
affordance (category: not family-friendly, bullying, **spam**, other). Reports
land in the admin queue at **`/admin` → Moderation** (`/admin/moderation`); each
new one also emails every admin, and the dashboard tile shows the open count.

On a case you **uphold** (owner gets a strike: warning → suspension →
deactivation), **reject** (unfreezes; can mark a report abusive), or, for
clear-cut spam, use the decisive **remove** buttons:

- **Deactivate account** — hides it site-wide, marks it internally as spam, and
  is **reversible**. Find such accounts later with the **"Removed as spam"**
  filter in the member browser (`/admin/users`) and press **Restore** to bring
  one back if the call was wrong.
- **Delete account** — permanent; erases the account and everything it posted
  (you get the usual deletion record email).

You don't have to catch every spammer by hand: once enough different members
independently report the same profile as **spam**, it is automatically frozen
pending your review. The nightly operator report lists the day's spam
deactivations. A spam mark is never shown publicly.
