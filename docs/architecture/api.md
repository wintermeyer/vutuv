# Third-party API (`/api/2.0`)

The third-party REST/JSON API lives at `/api/2.0` (Bearer tokens, JSON in/out).
Get started in two steps:

1. Create a personal access token at [`/access_tokens`](https://vutuv.de/access_tokens) (the form is pre-filled; the default `profile:read` scope is enough for reading).
2. ```bash
   curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" https://vutuv.de/api/2.0/me
   ```

## How it works

An authenticated REST/JSON API for scripts and third-party apps. Bearer tokens
only (no session/CSRF; CORS wide open since no cookie authenticates): members
mint **personal access tokens** at `/access_tokens` (scoped permissions like
`profile:read`/`posts:write`, mandatory 30/90/365-day expiry, shown exactly
once, SHA-256-hashed at rest, prefix `vutuv_pat_` for secret scanners; the
new-token form is pre-filled — dated name, `profile:read`, 90 days — so the
quickstart is one click) and revoke per token or all at once — every request
verifies against the DB, so revocation, account moderation and app suspension
bite on the very next request.

Reads go **through the authorizing member's eyes** (same visibility rules as the
website, via the AgentDocs doc builders with a `viewer`); writes go through the
same context functions as the UI, so blocking, moderation, audience locks,
cooldowns and live broadcasts behave identically.

Covered: profile (`PATCH /me`) + section CRUD (emails read-only — PIN-verified
identities), follow/unfollow (a mutual follow makes the pair vernetzt — no
separate connection lifecycle) + `GET …/relationship`, posts (compose with
deny-based audiences, replies, like/bookmark/repost switches, the
cursor-paginated `/feed` with signed opaque cursors), direct messages (request
model included; a declined request stays indistinguishable from silence) and the
notification feed.

Per-token rate limit (5,000/h, `X-RateLimit-*` headers), RFC 9457 problem+json
errors (422 with per-field messages), additive-only within `/api/2.0` (breaking
changes mean a new version prefix).

**OAuth 2** for real third-party apps (authorization code + mandatory PKCE S256,
confidential clients, rotating refresh tokens with reuse-revocation, RFC 7009
revocation): developers register apps at `/developers/apps` (self-service,
always owned by a vutuv account; `/admin/api_apps` is the suspend kill switch
that fails every app token on its next request), members approve scopes on the
`/oauth/authorize` consent screen and manage/withdraw access at
`/connected_apps`.

**Webhooks** (`Vutuv.Webhooks`): per-app subscriptions deliver signed thin event
envelopes (HMAC-SHA256 in `X-Vutuv-Signature`, ids/usernames only, never
content) for members who granted the matching scope; DB-backed queue with
exponential backoff drained by `Vutuv.Webhooks.Deliverer`, auto-disable after
sustained failure, test ping from the app page.

Developer docs in English with curl examples at `/developers` (Markdown files in
`priv/dev_docs/`, also served raw under `.md`): overview with a
development/bug-reporting section, authentication, a task-recipe cookbook ("how
do I post / send a DM?"), the data model (entities + visibility rules), the
endpoint reference and webhooks — linked from the footer of every page.

API profile responses carry the member's `noindex?`/`noai?` consent flags
in-band (the public `.json`/`.md` siblings signal the same via
`Content-Signal`/`X-Robots-Tag` headers)
