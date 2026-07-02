# Contributing to vutuv

Thanks for helping! The short version:

## Getting started

Follow the [Development Setup](README.md#development-setup) in the README
(`mise` for Erlang/Elixir, PostgreSQL 17, libvips, then `mix setup` and
`mix phx.server`). Emails land in the browser at
[/sent_emails](http://localhost:4000/sent_emails) — you'll need that for the
PIN login flow.

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
