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

Served on `mastodon.<PHX_HOST>` **and on the main host**;
`MASTODON_API_ENABLED=false` disables both. ActivityPub actors, WebFinger
handles, profiles and public post URLs live on `PHX_HOST` throughout.

The subdomain is the **preferred** origin: it serves no website pages (an
API-host catch-all refuses anything that is not an API route), and a reverse
proxy can give it its own CORS and security headers. It is **not** advertised
anywhere, and that is worth knowing before anybody decides whether to keep it.
`instance.uri` / `domain` are `PHX_HOST`, so are the actor ids, the WebFinger
answers and every post URL; `MastodonApi.api_url/1` is reached only from
`client_url/2`, which names the subdomain solely to a client that already
arrived on it. An installation that never sets the DNS record, the certificate
and the `server_name` therefore has nothing pointing at a host it does not
serve. But a member setting up a phone app types the address they
know, which is the main one, so the same routes answer there too. Without that,
typing `vutuv.de` gets a 404 from the client's first probe and the app reports
"not a Mastodon server".

**A redirect would have been the smaller change and does not work.** A client
keeps the host you typed and builds every later URL from it, and HTTP libraries
drop the `Authorization` header across a host change — so the login would land
and every authenticated call after it would come back 401. Hence two hosts
serving the same routes, and hence `oauth_metadata` naming endpoints on
whichever host the client arrived on (`MastodonApi.client_url/2`): a client is
never sent across mid-flow. The consent screen is the one deliberate exception,
because it is a browser page and lives on the main host either way.

The catch-all is **not** mirrored onto the main host, where it would swallow the
whole website; an unmatched `/api/v1/...` there falls through to the ordinary
404.

**What a member types, and what they then see.** The server address is
`vutuv.de` (or the subdomain, both work). The handle follows Mastodon's own
`LOCAL_DOMAIN`/`WEB_DOMAIN` convention: `acct` is the bare handle and
`instance.uri`/`domain` is `PHX_HOST`, so a client that composes the two shows
`@member@vutuv.de` — the same identity the fediverse knows. A client that
instead builds the handle from the host it talked to shows that host, which is
one more reason the main host answers.

## What works today

Server discovery, login and the core social workflow:

- `GET /.well-known/oauth-authorization-server`
- `GET /api/v1/instance` and `GET /api/v2/instance`
- `POST /api/v1/apps` and `GET /api/v1/apps/verify_credentials`
- `GET /oauth/authorize` (redirects the browser to the main origin)
- `POST /oauth/token` (`authorization_code`, `refresh_token`,
  `client_credentials`) and `POST /oauth/revoke`
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
non-public visibility need explicit Mastodon mappings before they can be
*written*; the adapter rejects an unsupported visibility instead of silently
publishing something broader. There is no video anywhere in vutuv, so there is
nothing to map there.

**Reading** does report audience, though. vutuv has no visibility column — a
post is public until it carries a `PostDenial`, and any denial at all closes it
to anonymous readers — so a post with denials is rendered `private`. That is not
Mastodon's followers-only, but it is the value that tells a client the post is
not for redistribution, so it stops offering boost on something its author
narrowed. Calling every post `public`, as the first cut did, told clients the
opposite.

**The figures under a status are the ones the website shows.** The three counts
and the reader's own like / bookmark / reshare come from
`Posts.post_engagement_map/2`, read once for the whole page the way the feed
pre-loads them for its cards (`Presenter.statuses/2` is the form every list
endpoint uses; `one_status/2` is the same path for a single row). Rendering them
without a viewer, as the first cut did, left every heart empty on a post the
member had just liked — so tapping it *removed* the like. `shown_counts/1` folds
in what other networks did with the same post, exactly as the card does.

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

### The app's own token (`client_credentials`)

A Mastodon client asks for a token for **itself** right after
`POST /api/v1/apps` and before it opens a browser — RFC 6749 §4.4, which
Mastodon's token endpoint answers. Refusing that grant does not cost a feature,
it ends setup: Ivory pointed at `vutuv.de` churned for a few seconds and gave up
with `unsupported_grant_type`, never reaching the consent screen, while
everything downstream of it — the two hosts, registration, discovery — was
already working. Diagnosing it took one `curl`: `client_credentials` answered
`unsupported_grant_type` where `authorization_code` with the same nonsense
credentials got as far as `invalid_client`.

**The production log confirms it, and reading that log needed one calibration.**
Six attempts from that phone, each 0–4 s after its own successful
`POST /api/v1/apps` and each answered 400, with not one `GET /oauth/authorize`
anywhere in the retained window: register, then ask for a token, with no member
authorization in between, which is this grant's flow and no other. It also rules
`authorization_code` out, because that one is implemented and would have answered
401. Which error body it was is **not** legible at a glance: nginx logs
`$body_bytes_sent`, the **compressed** length, so the 54 bytes match none of the
four error documents until the same documents are measured gzipped
(`unsupported_grant_type` 54, `invalid_client` 46 — a phone sends
`Accept-Encoding: gzip`, `curl` by default does not). Calibrate such a field
against a known input before believing what it says. What stays out of reach is
the literal `grant_type` the client sent: a wrong value, an unknown one and a
missing one all answer byte-identically, so no response can name it.

**Such a token lives in its own table** (`oauth_app_tokens`,
`Vutuv.ApiAuth.AppToken`) rather than beside the member tokens, and that is the
security property rather than a filing decision. `api_tokens.user_id` is NOT
NULL and `ApiAuth.lookup/1` reaches the member through an **inner join**, so a
userless row there would be dropped by that join without a word — the shape
CLAUDE.md records five separate incidents of. Widening the column would also
open an N-1 window in which the previous release meets a token it cannot read.
Keeping the two apart means every member-scoped endpoint authenticates through
`api_tokens` and therefore *cannot* accept an app token; nothing has to remember
a rule, and an endpoint added later inherits the refusal.

What such a token may do is correspondingly small:
`GET /api/v1/apps/verify_credentials`, which names the app and deliberately
echoes back neither `client_id` nor secret. It is the one Mastodon route not
behind `Plug.MastodonApiAuth` — it authenticates itself, because that plug's job
is to resolve a *member*, and this endpoint asks the reverse question. It
therefore answers for a **member** token as well, which is what Mastodon does
("a client credential or an access token") and what a client checking which app
its token belongs to expects; the two are resolved through their own tables, so
the widening stops at this route. It reads the `Authorization` header through
`Plug.MastodonApiAuth.bearer_token/1` rather than spelling it a second time: auth
scheme names are case-insensitive, and a second reading that only accepts
`Bearer` is a 401 for clients the rest of the adapter serves.

The grant is offered to `protocol: "mastodon"` apps only: a native vutuv OAuth
app is user-facing with mandatory PKCE and asked for no app-level credential, so
it keeps getting `unsupported_grant_type`. A requested `scope` is honoured within
what the app registered and refused as `invalid_scope` beyond it; omitting it
keeps the registered scopes.

**Two things this grant needs that the member grants get for free.** Only the
hash of a token is ever stored, so a live one cannot be handed back a second time
(Doorkeeper's `reuse_access_token` has no counterpart here) and every call mints a
row — while app registration is public and the token endpoint is not rate
limited, which is unbounded growth on an unattended path. `client_credentials`
therefore keeps only the newest few rows per app. And revocation has to search
this table too (`OAuth.revoke/1`): RFC 7009 lets the endpoint answer 200 for a
token it does not know, so a client revoking its own live app token would
otherwise be told 200 while the credential kept working.

### What setup leaves behind, and the budget on consent

Two tables fill up on their own here, and for a while nothing emptied either
(issue #1557). A client **registers itself before the consent screen**, so every
setup somebody starts and abandons leaves an ownerless `oauth_apps` row — that is
ordinary use, not a fault: opening a client and not finishing costs the same row
as a server-side refusal did. And every consent mints an `oauth_auth_codes` row
that is dead ten minutes later, redeemed or not. `Vutuv.ApiAuth.sweep/0` clears
both after a week, run daily by `Vutuv.ApiAuth.Sweeper`.

**What counts as abandoned is the whole of that function.** "No grant" is not
enough: a `client_credentials` app holds a live token and has no grant at all, so
that test alone would delete exactly the apps the newest feature serves. An app
goes only when nobody consented **and** it holds no live token. A spent code is
kept the same week rather than dropped at expiry, because the row is what makes a
**replay** detectable — `consume_code/1` reads `used_at` and revokes the grant's
tokens when a code comes back twice.

**One consent should mint one code, and for a while one login minted about a
hundred** (issue #1561): a phone client resubmitted `POST /oauth/authorize` from
a **single loaded page**, up to eight times a second, every one a 302 with a
valid CSRF token and a fresh code redeemable for ten minutes. Nothing here
resubmits that form — the template is a plain `<.form>`, and the three places in
`assets/js` that submit a form belong to the Markdown editor, WebAuthn and the
Fediverse dialog — so neither half of the answer chases that client's bug.

Two bounds, and they are not the same bound. `prune_unused_codes/2` keeps the
newest few **unused** codes per member and app at the mint site, which is what
caps how many are redeemable at once; a spent one is spared, because that row is
what `consume_code/1` reads to catch a replay. And the consent route carries a
budget of ten allowed submissions per member and app per minute — keyed on the
identity rather than the IP, so a client looping on one app cannot block
connecting another, and charged only for an "allow", so a stream of refusals
cannot lock out a genuine consent.

**The budget alone would not do**, which is the part worth remembering: a client
pacing itself just under any per-minute limit still accumulates codes for their
whole ten-minute life. Measured on the un-pruned code, the budget left ten
redeemable at once; the prune leaves three. What the budget buys is the wasted
round trips and a signal to the client that something is wrong. It sits far above
anything a person does, because it must never touch a working login.

### Paging, streaming and push

Every list takes Mastodon's `limit` / `max_id` / `since_id` / `min_id` and
answers a `Link` header (`VutuvWeb.MastodonApi.Pagination`). vutuv's ids do the
work: they are `Vutuv.UUIDv7`, whose first 48 bits are the creation time, so an
id comparison *is* a time comparison and no offset or stored cursor is needed.

**The boundary goes into the query, never into a filter over rows the query
already returned** (`Vutuv.Keyset`, which the context readers take as plain
options). This is worth stating as a rule because getting it wrong is invisible:
the first cut of this adapter fetched the newest `limit + 20` rows and filtered
the window out of them in memory, which works for two pages and then answers an
empty page — for that request and every one after it. A 200-post profile simply
looked like a 40-post one, with a 200 and no log line. `deep_pagination_test.exs`
walks each list past that old read; it is calibrated so that restoring the
in-memory window turns every case red.

A consequence worth knowing: **each list is ordered by the id a client hands
back**, which for a saved-posts list is the post id rather than when it was
saved, and for an account timeline the post id rather than the reshare time. A
list ordered by one column and paged by another repeats rows and skips others,
so there is no third option. The website's own pagers over the same data keep
their orders, their totals and their numbered pages.

The merged feeds — the home timeline and the merged `following` list — are the
exception, and only in how the page is *assembled*: several sources share no id
space, so no single query can order them. Each source is bounded by the same
window first and the page is picked from what they return together, so the
deepest page reads as few rows as the first. The home feed paginates by a
second-precision `{timestamp, seen ids}` cursor underneath, which cannot
separate entries written in the same second, so the cursor narrows the fetch to
the boundary second and the id comparison cuts; a page can come back short where
many entries tie, which ends a walk one round early and never repeats an entry.

**Streaming** is `/api/v1/streaming`, a `Phoenix.Socket.Transport` rather than a
channel, because Mastodon has its own frame format on the wire. It is mounted on
the shared endpoint (a socket cannot be host-scoped there) and applies the same
host test as the HTTP gate (`MastodonApi.client_host?/1`), so a client that
signed in on the main host can open a stream there too — demanding the subdomain
here let an app authenticate and then never connect.

**A photo that has not cleared the AI scan holds the announcement, not the
post.** `update` carries a finished status — an attachment list has no "still
processing" state (only the media endpoint does, as a `null` url) and a client
inserts the card once and never looks again. So a post whose pictures are still
being scanned is not announced at all, and the release arrives as
**`status.update`**, the event Mastodon has for a status whose content changed
after delivery; the client swaps the card in place. Announcing it early would
leave that one device showing a text-only post forever while every other surface
has the picture. The socket asks `Posts.awaiting_image_release?/1` itself rather
than relying on the post pipeline deferring its fan-out, because that deferral is
a property of the pipeline and not a promise to this socket. The **push
notification** is deliberately not held: it carries no content, the client
fetches over the API, and delaying "somebody replied to you" to wait on a
picture would be the wrong trade.

**The author's own view over an app is the same view.** On the website they get a
placeholder tile and a line saying the scan is running; a Mastodon client has
nowhere to put either, and their own pending photo cannot simply be handed to
them: `PostImageController` authorises unreleased bytes from the **browser
session** (`Posts.image_visible_to?/2` → `ImageScans.privileged_viewer?/2`), and
an app fetches a media URL with no credentials at all, so it would receive the
proxy's fail-closed 404 and render a broken image. A post with no attachment is
the better of the two. Note what is *not* sent: no attachment object at all,
rather than one with a `null` url — so a client renders a text post and cannot
be left with a placeholder that never resolves. `broadcast_images_settled/1`
reaches the author's own topic too, so their `status.update` arrives with
everybody else's.

Most clients never see any of this. Mastodon's own upload flow is
`POST /api/v2/media` → poll `GET /api/v1/media/:id` until the url is non-null →
*then* create the status, and that is exactly what the media endpoint's `null`
url means here. A client following it attaches a photo that has already cleared
the scan. The window above belongs to clients that post immediately with a
freshly uploaded id.

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
- **Account figures are filled on single accounts only.** `verify_credentials`
  and `/accounts/:id` carry real `followers_count`, `following_count` and
  `statuses_count`; an account inside a *list* (followers, mutes, who liked a
  status) carries zeros, because filling them there is three counts per row and
  no client shows the numbers in that position. `note` is filled everywhere —
  the member's headline or the page's description, escaped and wrapped in one
  paragraph, since Mastodon's `note` is HTML and ours is text a member typed.
  `last_status_at` is still always `nil`.
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
- **`mastodon_clients?` defaults to `false`** for members and organizations
  alike: signing in from a phone app is opted into, not out of. Most members will
  never want it, and a switch nobody turned on is one fewer way in for an account
  that is not using it. The two are separate columns because they are separate
  decisions — a member allowing apps for themselves says nothing about a page
  their team runs. A member turns theirs on under `/settings/apps`, an owner
  turns a page's on under `/organizations/<slug>/apps`, and either takes effect
  on the next request. Because it ships off, both pages have to name the address
  a member types (from `Endpoint.host()`, never a literal) and link
  `/system/mastodon`; the adapter was otherwise undiscoverable from inside the
  product, which is a worse failure than a missing endpoint.
