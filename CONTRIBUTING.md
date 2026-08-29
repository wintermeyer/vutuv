# Contributing to vutuv

Thanks for helping! The short version:

## Getting started

Follow the [Development Setup](docs/DEVELOPERS.md#development-setup) in the
developer guide (`mise` for Erlang/Elixir, PostgreSQL 17, libvips, then
`mix setup` and `mix phx.server`). Emails land in the browser at
[/sent_emails](http://localhost:4000/sent_emails) — you'll need that for the
PIN login flow. Installing vutuv to *run* it (rather than develop it) is
covered separately in [docs/ADMINS.md](docs/ADMINS.md).

## Working from a fork

Pull requests are opened against this repository, so `upstream` — not your
fork — is what you branch from. Set that up once after cloning:

```bash
git remote add upstream https://github.com/wintermeyer/vutuv.git
git remote set-url --push upstream DISABLED   # a stray push must not aim here
git fetch upstream
gh repo set-default wintermeyer/vutuv         # gh pr create / merge target this repo
```

Then branch from and rebase onto `upstream/main`. Push only to `origin`; keep
your fork's `main` a mirror with
`gh repo sync <you>/vutuv --source wintermeyer/vutuv --branch main` and never
commit to it.

## Ground rules

- **Start every feature or bugfix with a test** that covers it, then make it
  pass.
- **Run `mix precommit` before pushing** — CI runs exactly this alias
  (compile with `--warnings-as-errors`, `credo --strict`,
  `mix format --check-formatted`, `mix test`). Don't push if it fails.
- **Migrations must stay backward-compatible for one release** (blue/green
  deploys run them while the previous release still serves traffic). Plain
  additions are fine in one step; removals take two (stop using it first,
  drop it in the next deploy).
- **Every id is a UUID v7** (`Vutuv.UUIDv7`) — never integer ids, never
  UUID v4, never `Ecto.UUID.generate/0`.
- **All email goes through `Vutuv.Notifications.Emailer`** (`base_email/0` +
  `deliver/1`); regression tests fail the build on bypasses.
- Public pages have Markdown/text/JSON/XML siblings built from one doc map
  (`VutuvWeb.AgentDocs`). If you change what a public HTML page shows,
  update its doc builder too — a drift test will remind you.

## Working on the API

The third-party API lives at `/api/2.0`; its documentation is written in
Markdown under [`priv/dev_docs/`](priv/dev_docs/) and served at
[/developers](https://vutuv.de/developers). Doc changes are just Markdown
edits — please keep the curl examples runnable.

## Reporting problems

Open a [GitHub issue](https://github.com/wintermeyer/vutuv/issues) with steps
to reproduce, or — for anything security-sensitive — follow
[SECURITY.md](SECURITY.md) instead of a public issue.
