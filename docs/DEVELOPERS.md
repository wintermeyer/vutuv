# Developing vutuv

Everything a developer needs to work on the vutuv codebase: local setup,
tests and how the reference installation (vutuv.de) is deployed. The
architecture itself is documented one subsystem per file in
[`docs/architecture/`](architecture/README.md).

Related documents: [README](../README.md) (overview) ·
[Running your own vutuv](ADMINS.md) (installation & operation) ·
[Architecture](architecture/README.md) (how the codebase is built) ·
[CONTRIBUTING](../CONTRIBUTING.md) (ground rules for changes) ·
[/developers](https://vutuv.de/developers) (the REST API, sources in
[`priv/dev_docs/`](../priv/dev_docs/)).

## Development Setup

vutuv is a [Phoenix Framework](https://www.phoenixframework.org/) 1.8 application. Prerequisites:

- Erlang 28.5.0.1, Elixir 1.20.0-otp-28 and Node.js 24 — install via [mise](https://mise.jdx.dev/) (pinned in `.tool-versions`)
- [PostgreSQL](https://www.postgresql.org/) 17 — installed separately (not covered by `.tool-versions`)

Two system libraries are also required (not managed by mise):

- **libvips** — all image processing (avatars, cover photos, post images, URL screenshots) goes through the [`image`](https://hex.pm/packages/image) package, which needs libvips. Install with `brew install vips` (macOS) or `apt-get install libvips-dev` (Debian/Ubuntu).
- **Chromium** (optional) — only needed for URL screenshots and moderation evidence screenshots; set `CHROMIUM_PATH` if the binary is not on `$PATH`.

esbuild and Tailwind themselves are Elixir deps (no global install). Node.js is
needed only to fetch the JS libraries bundled into `app.js` — currently
[Milkdown](https://milkdown.dev/), the WYSIWYG Markdown editor behind the post and
message composers (`assets/package.json`). `mix assets.setup` runs `npm ci` in
`assets/`, so a plain `mix setup` pulls everything; `assets/node_modules` is
gitignored and the lockfile is committed, so the build stays reproducible.

### Secret config

Create `config/dev.secret.exs`:
```elixir
import Config

config :vutuv, VutuvWeb.Endpoint,
  secret_key_base: "generate-with-mix-phx-gen-secret"
```

### Start the application

```bash
mix setup           # deps.get + npm ci + ecto.create/migrate/seeds + esbuild/tailwind install
mix phx.server
```

Visit http://localhost:4000. (`mix setup` does everything except the
`config/dev.secret.exs` step above.)

### Email in development

Emails are displayed in the browser via Swoosh's mailbox preview at http://localhost:4000/sent_emails.

The email architecture (the single `Emailer` chokepoint, the multipart
text + HTML bodies, bounce handling) is described in
[architecture/email.md](architecture/email.md).

### AI tooling in development

[Tidewave](https://tidewave.ai) runs in the dev server (dev-only dependency): AI coding agents can connect to the MCP endpoint at http://localhost:4000/tidewave/mcp to eval code in the running app, query Ecto and read logs.

### Admin access

Grant your account admin rights (the `admin?` flag is deliberately never
settable through a form or the API):
```bash
mix vutuv.admin.promote your-handle     # also takes an email address
```
On a production release (no Mix): `bin/vutuv eval 'Vutuv.Release.promote_admin("your-handle")'`.

The admin panel itself (the live dashboard and every admin page) is described
in [architecture/admin.md](architecture/admin.md).

## Architecture

One document per subsystem in [`docs/architecture/`](architecture/README.md):
the real-time LiveView shell, the social graph, posts & the feed, search,
direct messages, profiles, settings & account, authentication, moderation,
the agent formats & SEO, email, images, the admin panel, the daily text ad
and the `/api/2.0` API. The [index](architecture/README.md) also carries the
stack conventions and the context-module map.

## Running tests

```bash
mix test
```

## How vutuv.de itself is deployed

This section describes the **reference installation** (vutuv.de). For
installing your own vutuv see [Running your own vutuv](ADMINS.md).

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

The production nginx/uploads layout, the email bounce handling and the
maintenance tasks (image regeneration, screenshots) are documented in
[Running your own vutuv](ADMINS.md) — production (vutuv.de) uses exactly
those mechanisms with `UPLOADS_DIR_PREFIX=/srv/vutuv3`. The full mail
topology of the vutuv.de host lives in
[`production-email-and-bounces.md`](production-email-and-bounces.md).
