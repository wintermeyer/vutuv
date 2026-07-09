# Running your own vutuv

vutuv is free, open-source software (MIT license): any company or person can
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
| `MAILER_FROM_NAME` | `vutuv` | Display name of the From on every email |
| `MAILER_FROM_ADDRESS` | `no-reply@vutuv.de` | **Set this.** From address on every email |
| `BOUNCE_ADDRESS` | `bounces@vutuv.de` | **Set this.** SMTP envelope sender (where bounces return) |
| `OPERATOR_NAME` | `Wintermeyer Consulting` | **Set this.** Your name: site/email footer credit and operator-notice recipient name |
| `OPERATOR_EMAIL` | `sw@wintermeyer-consulting.de` | **Set this.** Receives the daily report, ad bookings and account-deletion records; also the `security.txt` contact |
| `OPERATOR_URL` | `https://wintermeyer-consulting.de` | **Set this.** Linked from the site/email footer |
| `OPERATOR_ADDRESS` | (vutuv.de's) | **Set this.** One-line postal address in every email footer |
| `APPEAL_REPLY_TO` | (vutuv.de's) | Reply-To on the account-deactivation (strike 3) email |
| `BOUNCE_WEBHOOK_TOKEN` | – | Bearer token for `POST /webhooks/bounces`; unset = bounce handling off |
| `MAIL_LOG_PATH` | `/var/log/mail.log` | Postfix log the bounce watcher tails; `""` = watcher off |
| `FEDIVERSE_ENABLED` | `true` | `false` turns follow-only ActivityPub federation off entirely (endpoints 404, nothing is delivered) — set it on intranet installations |
| `MAIL_LOG_POLL_MS` | `5000` | Bounce watcher poll interval |
| `INVITATION_DAILY_CAP` | `50` | Most invitations a single member may send per day (abuse guard on outbound invite email) |

The defaults marked **Set this** are vutuv.de's operator identity — a fresh
installation should override all of them on day one, or your daily reports
will try to reach vutuv.de's operator.

A few rarely-changed switches are compile-time settings in
`config/config.exs` / `config/prod.exs` (edit before `mix release`):
`:ads_enabled` (the daily text-ad system, off by default),
`:ai_crawler_policy` (`:permissive` or `:block_training` — drives robots.txt
and the Content-Signal headers), `:fetch_gravatar`, `:fetch_mastodon_posts`,
`:fetch_bluesky_posts`, `:generate_screenshots`, and
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
- Turn off the features that call out to the internet (compile-time flags in
  `config/config.exs`): `:fetch_gravatar` (avatar lookup at registration),
  `:fetch_mastodon_posts` / `:fetch_bluesky_posts` (the social-feed card on
  profiles), and `:generate_screenshots` (link preview screenshots — these
  fetch the linked page).
- The map links on profile addresses (Google/OSM/Apple) are plain link-outs
  rendered in the visitor's browser; they simply won't resolve offline.
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
- `bin/vutuv eval 'Vutuv.Release.promote_admin("handle-or-email")'` — grants
  admin rights.

(In a source checkout the same exist as `mix vutuv.images.regenerate` /
`mix vutuv.admin.promote`; URL screenshots can be re-rendered with
`mix urls.create_screenshots`.)

Note: `bin/vutuv eval` is the supported console entry point; `rpc`/`remote`
need distribution, which the reference setup disables.

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
