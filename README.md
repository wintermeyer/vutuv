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
- **Real-time shell (LiveView)**: the app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with live unread badges) is embedded in the shared `app` layout via `live_render`, so the chrome and badges are live on every page. The **Messages** (`/messages`) and **Notifications** (`/notifications`) pages are LiveViews under a `live_session`. In-app updates flow over `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"`); online status and typing use `VutuvWeb.Presence`. The layout is split into `root.html.heex` (document shell) and `app.html.heex` (chrome), shared by classic controller pages and LiveViews. Messages/notifications currently use dummy data; persistence is a follow-up.
- **Routes**: Verified routes (`~p"..."` sigils)
- **Forms**: `<.form>` component with `<.inputs_for>` for nested forms
- **Assets**: esbuild + Tailwind CSS v4; dark mode follows the system (`prefers-color-scheme`, no toggle) — legacy pages get their dark styles centrally from `assets/css/components.css`
- **HTTP server**: Bandit
- **Email**: Swoosh with compile-time EEx text templates; all mail built from `Emailer.base_email/0` and sent through one `Emailer.deliver/1` chokepoint that stamps the auto-generated robot headers
- **Images**: avatars and URL screenshots are stored on local disk and resized with [`image`](https://hex.pm/packages/image) (libvips); see `Vutuv.Avatar` / `Vutuv.Screenshot`
- **URL screenshots**: rendered by local headless Chromium, wrapped in a browser window frame (`Vutuv.BrowserFrame`) and stored as WebP; see `Vutuv.PageScreenshot`. Needs a `chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on `$PATH`)

### Context modules

Business logic is organized into Phoenix context modules under `lib/vutuv/`:

| Context | Schemas | Purpose |
|---|---|---|
| `Vutuv.Accounts` | User, Email, Slug, SearchTerm, OAuthProvider, LoginPin, Locale, Exonym | Registration, PIN-based authentication, user management |
| `Vutuv.Profiles` | Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience, UserSkill, Skill, Endorsement | User profile data |
| `Vutuv.Social` | Connection, Group, Membership | Following, groups |
| `Vutuv.Tags` | Tag, UserTag, UserTagEndorsement | Tagging and endorsements |
| `Vutuv.Recruiting` | RecruiterPackage, RecruiterSubscription, Coupon | Recruiter subscriptions |
| `Vutuv.JobPostings` | JobPosting, JobPostingTag | Job listings |
| `Vutuv.Search` | SearchQuery, SearchQueryRequester, SearchQueryResult | Search functionality |
| `Vutuv.Notifications` | Emailer, Cronjob | Email notifications |

## Running tests

```bash
mix test
```

## Deployment

Deployment is automatic. Two GitHub Actions workflows drive it:

- **CI** (`.github/workflows/ci.yml`) runs `mix precommit` (compile with `--warnings-as-errors`, unused-deps, format, `credo --strict`, tests) on every pull request and on pushes to `main`.
- **Deploy** (`.github/workflows/deploy.yml`) runs on every push to `main`. So **merging or pushing anything to `main` ships it to production**; there is no separate deploy command.

The Deploy job runs on the self-hosted `vutuv3` runner (on bremen2) and executes `scripts/deploy.sh`, which builds a `prod` release, runs migrations against `vutuv3_prod`, atomically flips the `current` symlink, and restarts the `vutuv3` systemd service. A `deploy-production` concurrency group ensures two production deploys never overlap. nginx is not touched by the script.

## Maintenance / ops tasks

These tasks operate on the on-disk uploads under `<UPLOADS_DIR_PREFIX>/...` (see `config/runtime.exs`). They are meant to be run manually on the server.

- `mix avatar.optimize` re-compresses the large JPEG avatar variants in `<UPLOADS_DIR_PREFIX>/avatars/`. Requires the ImageMagick `convert` and `guetzli` binaries on the host's `$PATH`.
- `mix urls.create_screenshots` (re)renders URL screenshots. Needs the headless Chromium binary already described above (set `CHROMIUM_PATH` if it is not on `$PATH`).
