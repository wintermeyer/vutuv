# vutuv

Many people call vutuv **the LinkedIn of the Fediverse**: a free, fast and
open source social network for the profiles of humans and organizations. It
began as a LinkedIn alternative and picked up the good parts of X and
Facebook along the way: posts, likes, reposts, replies and direct messages.
And it federates, so members can be followed from Mastodon and the rest of
the Fediverse (ActivityPub, opt-in per member). The reference installation
runs at
[vutuv.de](https://vutuv.de); **anyone can run their own** — on the public
internet or inside a company intranet.

We use the [MIT License](LICENSE).

## What it does

- Public member profiles (work experience, education, spoken languages, tags,
  links, contact details) with follow relationships, posts, likes/reposts/replies and
  1:1 direct messages — all real-time (Phoenix LiveView) where it matters.
- **Passwordless**: login by emailed PIN, optionally passkeys (WebAuthn).
- Agent-ready: every public page is also served as Markdown, plain text, JSON
  and XML; RSS feeds, sitemap, JSON-LD, `/llms.txt` and a REST API
  (`/api/2.0`, OAuth 2 + personal access tokens, webhooks).
- Built-in moderation (family-friendly by design), admin panel, newsletter
  system, GDPR data export, a formatted CV (Lebenslauf) download for job
  applications (print/PDF, Word, OpenDocument, LaTeX, JSON Resume), and
  per-installation legal pages (Impressum, Datenschutzerklärung,
  Nutzungsbedingungen) edited at `/admin/legal`.
- German and English UI; dark mode follows the system.

Technology: Elixir / Phoenix 1.8, PostgreSQL, Bandit, Tailwind CSS v4,
libvips (AVIF images). A single modest server goes a long way (vutuv.de has
yet to outgrow one), and because vutuv is built on Elixir it scales out to
multiple nodes for very large installations.

## Run your own installation

The operator's manual — requirements, release build, configuration reference,
nginx, first admin, legal pages, intranet setups, backups and upgrades —
lives in **[docs/ADMINS.md](docs/ADMINS.md)**.

**We'd love to hear about your installation.** If you run vutuv (intranet or
internet), tell us — and send feedback, bug reports and feature requests —
via [GitHub issues](https://github.com/wintermeyer/vutuv/issues/new).

## Development

```bash
mise install          # Erlang + Elixir (pinned in .tool-versions)
mix setup             # deps, database, assets
mix phx.server        # http://localhost:4000
```

The developer guide (prerequisites, setup, tests, how vutuv.de itself is
deployed) lives in **[docs/DEVELOPERS.md](docs/DEVELOPERS.md)**; the
architecture is documented one subsystem per file in
**[docs/architecture/](docs/architecture/README.md)**. Ground rules for
contributions: **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## API

Third-party REST/JSON API at `/api/2.0` (Bearer tokens). Create a personal
access token at [`/access_tokens`](https://vutuv.de/access_tokens), then:

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" https://vutuv.de/api/2.0/me
```

Full developer documentation is served at
[`/developers`](https://vutuv.de/developers) (sources:
[`priv/dev_docs/`](priv/dev_docs/)).
