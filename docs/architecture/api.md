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
model included; a declined request stays indistinguishable from silence), the
notification feed, and **jobs + organizations** (issue #936, `jobs:read` /
`jobs:write`): the viewer-scoped board `GET /jobs` (same filters as the website),
`GET /jobs/:id`, the poster's own lifecycle `POST /jobs` (create or publish),
`PATCH /jobs/:id`, `POST /jobs/:id/closure`, `DELETE /jobs/:id` (all through the
same `Vutuv.Jobs` changesets, quota gate and 90-day lifecycle as the `/jobs`
forms — an API posting is indistinguishable), plus read-only `GET /organizations`
and `GET /organizations/:slug`. Applications and people search stay out of scope.

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

The consent screen is the one page whose form is *meant* to end up off-site,
and that collides with the site-wide `form-action 'self'` in
`VutuvWeb.Plug.ContentSecurityPolicy`: browsers enforce `form-action` on every
hop of a submission, **redirects included**, so the 302 to the client's
`redirect_uri` (`ivory://…` for a phone client, an off-origin `https://`
callback for a web one) was refused. Nothing about that failure is visible —
the POST arrives, the code is minted, and the member is left on the consent
screen with no token and no error, which is what an Ivory user reported as a
dead "Allow access" button. So both legs of `/oauth/authorize` re-stamp the
policy through `ContentSecurityPolicy.allow_form_action/2` with the app's
**validated** redirect URI: the exact origin for `http(s)`, the bare scheme
(`ivory:`) for a native client's own scheme. It is never built from the raw
query parameter — `OAuth.validate_authorize/1` has already matched it against
the app's registered `redirect_uris`, so the policy names a destination the
server was going to redirect to anyway. Scheme and host are still re-checked
where the source is spelled, because registration is public and `URI.parse/1`
validates nothing: `https://evil.example.org;script-src 'unsafe-inline'/cb`
registers cleanly and comes back with that whole run as its "host", which in a
header would be a second directive of the app author's choosing.

**Who holds a credential, and who may take it away.** `/connected_apps` names,
per authorization, when it was given and which devices still hold a live token
under it (`Vutuv.ApiAuth.UserAgent` reads a short platform label out of the
client string stored on the token; nothing recognisable stays "unknown device"
rather than becoming a guess). That is not cosmetic: a Mastodon client registers
a **new** OAuth app per install, so several installs are several rows of one
name, and without a time and a device there was nothing to pick the right one
by. The page twin is `/organizations/:slug/apps`, where the **owner** sees every
token issued for the page — filtered by the issuing member, paged, each
withdrawable on its own — because a member issues such a token of their own
accord and until then only they could see or stop it. Turning the page's app
access off withdraws them all, after a confirmation that names how many:
leaving them alive would make the switch a lie, since they stop working while it
is off and would come back the moment somebody turned it on again.

**Webhooks** (`Vutuv.Webhooks`): per-app subscriptions deliver signed thin event
envelopes (HMAC-SHA256 in `X-Vutuv-Signature`, ids/usernames only, never
content) for members who granted the matching scope; DB-backed queue with
exponential backoff drained by `Vutuv.Webhooks.Deliverer`, auto-disable after
sustained failure, test ping from the app page. The one exception to the
content-free envelope is `job.published` (issue #936, needs the poster's
`jobs:read` grant, emitted from `Vutuv.Jobs.publish/4`): because a published
posting is public, its payload carries the posting's public structured fields
(title, location, salary, tags) so an integrator can mirror an opening without a
follow-up fetch.

Developer docs in English with curl examples at `/developers` (Markdown files in
`priv/dev_docs/`, also served raw under `.md`): overview with a
development/bug-reporting section, authentication, a task-recipe cookbook ("how
do I post / send a DM?"), the data model (entities + visibility rules), the
endpoint reference, the Jobs API chapter (postings, organizations, lifecycle,
`job.published`) and webhooks — linked from the footer of every page.

API profile responses carry the member's `noindex?`/`noai?` consent flags
in-band (the public `.json`/`.md` siblings signal the same via
`Content-Signal`/`X-Robots-Tag` headers)


## The Mastodon-compatible surface is elsewhere

Installations also serve a Mastodon-compatible client API on
`mastodon.<PHX_HOST>`, so existing phone clients can sign in. It shares this
app's data and permission model but none of its URLs, and it is documented on
its own in [mastodon-api.md](mastodon-api.md).
