# Mastodon-compatible client API (`mastodon.<PHX_HOST>`)

A compatibility surface that lets existing Mastodon phone clients sign in to
vutuv and use it as an account. It is **not** the third-party API — that one is
[api.md](api.md), it lives at `/api/2.0` on the main host and its contract is
unchanged by anything here.

The two are kept apart on purpose, and the separate host is the reason this
document is separate too: Mastodon's paths (`/api/v1/...`, `/oauth/token`) are
not ours to shape, and pinning them to their own origin means neither surface
constrains the other's URLs, headers or CORS. A future Pixelfed-compatible
surface would get its own host and its own document beside this one, for the
same reason.

## The host

Served on `mastodon.<PHX_HOST>` by default; `MASTODON_API_ENABLED=false`
disables it. ActivityPub actors,
WebFinger handles, profiles and public post URLs stay on `PHX_HOST`; the
subdomain is only the technical REST/OAuth origin entered in a phone client.
It serves no website pages (an API-host catch-all refuses anything that is not
an API route), so a reverse proxy can apply CORS and security headers
independently from the main site.

## What works today

Server discovery, login and the core social workflow:

- `GET /.well-known/oauth-authorization-server`
- `GET /api/v1/instance` and `GET /api/v2/instance`
- `POST /api/v1/apps`
- `GET /oauth/authorize` (redirects the browser to the main origin)
- `POST /oauth/token` and `POST /oauth/revoke`
- `GET /api/v1/accounts/verify_credentials`
- `GET /api/v1/timelines/home`
- reading, creating, editing and deleting statuses, plus personal replies
- `POST /api/v1/media`, `POST /api/v2/media`, `GET /api/v1/media/:id` and
  `PUT /api/v1/media/:id` for photo attachments
- favourite/unfavourite, reblog/unreblog and bookmark/unbookmark status actions
- account lookup, relationships and following lists; follow/unfollow,
  mute/unmute and the local member block/unblock operations that vutuv already
  supports
- `GET /api/v2/search` — accounts, statuses and hashtags, plus exact
  `@user@host` resolution
- `GET /api/v1/statuses/:id/context` and `/source`
- `GET /api/v1/timelines/public` and `/timelines/tag/:hashtag`
- `GET /api/v1/notifications` (+ `/unread_count`, `/clear`, `/:id`)
- `GET /api/v1/bookmarks`, `/favourites`, `/blocks`, `/mutes`,
  `/accounts/:id/followers`, `/statuses/:id/favourited_by` and `/reblogged_by`
- `PATCH /api/v1/accounts/update_credentials` and `POST /api/v1/reports`
- `POST|GET|PUT|DELETE /api/v1/push/subscription`
- the streaming websocket at `/api/v1/streaming`

Status creation accepts public text posts with photos. Organization posts are
top-level, matching vutuv's existing organization post model. Polls and
non-public visibility need explicit Mastodon mappings before they can be added;
the adapter rejects an unsupported visibility instead of silently publishing
something broader. There is no video anywhere in vutuv, so there is nothing to
map there.

### Photos

`POST /api/v1/media` and `POST /api/v2/media` (multipart, the file in `file`,
optional `description`) create a pending image; its id goes into `media_ids[]`
on `POST /api/v1/statuses`, and `PUT /api/v1/statuses/:id` takes the same
parameter to add or drop one on an edit. `PUT /api/v1/media/:id` sets the
description afterwards. Same store, sweeper (unattached uploads are removed
after a day) and audience proxy as a photo added in the web composer — an
unattached `Vutuv.Posts.PostImage` row simply *is* the Mastodon attachment.
Accepted: `.jpg .jpeg .png .webp`, plus `.heic/.heif` where the host supports
them, up to `Posts.max_image_filesize/0` and `Posts.max_images_per_post/0` per
status. Uploads are rate limited per member.

**The AI image scan is why the v2 endpoint is worth having.** A fresh upload is
`pending` and `Posts.moderation_hidden?/1` keeps the whole post owner-only
until every picture is released, which the website renders as the amber "only
you can see this so far" panel. A phone client has nowhere to put that, so the
adapter uses the state Mastodon already defines rather than publishing into
limbo: **v2 answers `202` with a `url` of `null`**, the client polls
`GET /api/v1/media/:id` (**`206`** while it waits, **`200`** once ready) and
posts when the picture is through. v1 keeps its synchronous `200` for clients
that do not poll; such a post then behaves exactly like its website twin. Where
an installation runs with `moderate_images` off, images are ready immediately
and both endpoints answer `200`.

`media_ids[]` resolve against the **acting member's** own unattached uploads,
never the organization's — a page has no uploads of its own, its pictures are
the ones its publisher put there. A stale or foreign id is a 422 rather than a
rollback from underneath.

Mastodon app registrations are unattended and therefore have no developer
owner, but they remain visible to the operator and use the same suspension kill
switch as native apps. Their grants store Mastodon's scope strings separately:
`read` never becomes `profile:read`, and `write` never inherits the native
API's write-implies-read rule. Legacy clients may omit PKCE because Mastodon has
historically made it optional; native vutuv OAuth apps still require S256.
Mastodon access tokens follow the client ecosystem's non-expiring convention
and are revocable from Connected apps or through `/oauth/revoke`.

Every token has one fixed identity: the member or one organization selected on
the consent screen. Blocking is available only for a personal identity against
another local member because that is the block relationship vutuv currently
stores; organization and remote account blocks are not invented by the adapter.
Private organization and remote follow lists are returned only to a token for
the identity that owns them.

**The adapter introduces no role of its own.** An organization identity resolves
through `Organizations.publisher?/2` — the same predicate
`acting_organization/2` asks for the browser's identity switch — so a client is
a second channel onto the powers the Redaktion already has on the website,
never a new power and never a new grant. Owner and Admin gain nothing silently,
exactly as on the website. Powers are re-derived from live roles on **every**
request, so withdrawing a role or switching off Mastodon-client access narrows
an existing token at once rather than at some expiry — which matters more here
than anywhere else, because these tokens have none. The per-identity switch is a
kill switch over the transport; it never changes what a role permits on the
website.

Letting a whole workforce *read* an organization's feed without being able to
speak in its name needs a role split that this adapter deliberately did not
make on its way past. It is designed under "The staff feed" in
[organizations.md](organizations.md).

### Paging, streaming and push

Every list takes Mastodon's `limit` / `max_id` / `since_id` / `min_id` and
answers a `Link` header (`VutuvWeb.MastodonApi.Pagination`). vutuv's ids do the
work: they are `Vutuv.UUIDv7`, whose first 48 bits are the creation time, so an
id comparison *is* a time comparison and no offset or stored cursor is needed.
The merged feeds paginate by a second-precision `{timestamp, seen ids}` cursor
underneath, which cannot separate entries written in the same second — so the
cursor only narrows the fetch to the boundary second and the id comparison
cuts. A page can therefore come back short where many entries tie, which ends a
walk one round early and never repeats an entry.

**Streaming** is `/api/v1/streaming`, a `Phoenix.Socket.Transport` rather than a
channel, because Mastodon has its own frame format on the wire. It is mounted on
the shared endpoint (a socket cannot be host-scoped there) and checks the API
host itself, so the path stays inert on the main origin.

**Push** is RFC 8291/8292 Web Push, implemented in `Vutuv.MastodonApi.WebPush`
with **no dependency**: the obvious hex package requires `httpoison ~> 1.0`,
which this project bans, and has not shipped since 2021 — everything needed is
in OTP's `:crypto`, and delivery goes through `Req` like every other outbound
call. A subscription is keyed on the access token, so one device is one
subscription and revoking an app takes it along. A push carries **no content**:
the kind and the notification id, nothing else, so neither the push service nor
a lock screen learns what was written. Off unless an operator sets a VAPID key
pair (`docs/ADMINS.md`).

### Known gaps and deferred decisions

Nothing here is a bug in what ships; each is a place where a client sees less
than it asks for, or a decision that was left open on purpose.

- **Some startup stubs still answer empty.** `conversations`, `lists`,
  `followed_tags`, `filters` and `markers` return `[]`/`{}`
  (`MastodonApi.CompatibilityController`). Notifications no longer do. vutuv has
  real filters (muted words and tags), real direct messages and real followed
  tags behind three of those, so they are the next worthwhile ones.
- **vutuv's own notification kinds are not pushed or listed.** Tag
  endorsements, CV updates, moderation cases, role grants and handle changes
  have no Mastodon type; serving them under an invented one is worse than
  leaving them out, because a client can neither render nor act on it. They
  stay on the website.
- **Pinned statuses are not exposed.** vutuv has them (#1110); `/statuses/:id/pin`
  is not wired up.
- **An organization's home timeline is decorated per acting member.**
  `Posts.organization_feed_page/2` takes the signed-in member as `viewer`, so
  two publishers reading the same page through their own clients see the same
  posts — the sources are scoped anonymously — but their own repost and
  remote-like state differs. This matches what `OrganizationLive.Feed` passes on
  the website and is the same reasoning as the staff feed's: the reading is the
  page's, the interaction state is the reader's.
- **Streaming carries the `user` stream only.** `public` and `hashtag`
  subscriptions are accepted and stay silent, because vutuv broadcasts nothing
  site-wide — a subscription that never fires beats an error a client retries
  forever. The socket re-verifies the token and re-derives the identity on
  connect, but cannot notice a role withdrawn *mid-connection*; every payload is
  a status the member may already read, so the exposure is the connection's
  lifetime rather than the token's.
- **Account counts are hardcoded to zero.** `followers_count`, `statuses_count`
  and `last_status_at` in `MastodonApi.Presenter.base_account/1`; only
  `verify_credentials` fills `following_count`. Clients therefore render every
  profile as having no followers and no posts.
- **A grant is keyed on `(user_id, app_id)`, not on the identity.** Authorizing
  the same client once personally and once as a page folds both consents into
  one `Grant` row whose scopes are the union. Enforcement is unaffected (the
  auth code and the token each carry their own narrowed scopes, and the plug
  re-derives per request), but Connected apps overstates what the organization
  token may do, and revoking there revokes every identity at once. Fixing it
  means keying grants by identity, which changes what Connected apps lists.
- **Non-JSON requests to the API host answer 406, not 404.** The pipeline runs
  `accepts ["json"]` before the catch-all route, so a browser opening
  `https://mastodon.<host>/` raises `Phoenix.NotAcceptableError`. The intent —
  no website pages on the API origin — holds either way.
- **`mastodon_clients?` defaults to `true`** for members and organizations
  alike, so an installation's existing accounts are opted in when the migration
  runs. Nothing becomes reachable without an explicit OAuth consent, and the
  flag is a kill switch rather than the gate; the open question is whether a new
  remote channel should default on for accounts whose owners never asked for it.
