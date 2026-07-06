# Fediverse (follow-only ActivityPub federation)

People on Mastodon and other ActivityPub servers can follow an opted-in
member and receive their **public** posts. Federation is outbound-only by
design: no remote posts, likes or replies are stored — the inbox only
processes `Follow` and `Undo(Follow)`; everything else is acknowledged (202)
and dropped. Everything lives in `Vutuv.Fediverse`.

## Consent first

Deleting federated copies on remote servers is advisory by protocol — it can
never be enforced. So federation is **opt-in per member**
(`users.fediverse_followers?`, the `/settings/fediverse` page; enabling mints
the actor keypair) and gated by an account in good standing
(`Vutuv.Fediverse.federated?/1`: opt-in + confirmed + not
frozen/suspended/deactivated). On top sits the installation-wide switch
`:fediverse_enabled` (`FEDIVERSE_ENABLED=false` for intranets): off means
every endpoint 404s and nothing is delivered.

## The moving parts

- **Actor** (`Vutuv.Fediverse.Actor`): the member's RSA-2048 keypair
  (`Vutuv.Fediverse.Keys`), created lazily on opt-in. The documents are built
  by `VutuvWeb.Fediverse.Docs`; URLs hang off the member so no root slug is
  burned: `/:username/actor` (id), `.../inbox`, `.../followers` and
  `.../outbox` (count-only collections).
- **Discovery**: `GET /.well-known/webfinger?resource=acct:handle@host`
  answers with the actor URL — how Mastodon's search resolves
  `@handle@vutuv.de`. The profile URL itself answers an
  `Accept: application/activity+json` with the actor document (the `:browser`
  pipeline accepts `activity+json` for exactly this), and the profile HTML
  head advertises `<link rel="alternate" type="application/activity+json">`.
- **Inbox** (`POST /:slug/actor/inbox`, `VutuvWeb.FediverseController`):
  verifies the draft-cavage HTTP signature (`Vutuv.Fediverse.HttpSignature`)
  against the key of the actor named in `keyId` — fetched SSRF-guarded and
  size-capped (`fetch_remote_actor/2`, signed GETs so authorized-fetch
  instances answer). The raw body for the digest check survives
  `Plug.Parsers` via `VutuvWeb.RawBodyReader` (endpoint `body_reader`, caches
  only this path). The activity's `actor` must equal the key owner
  (anti-spoofing). A valid `Follow` stores the follower
  (`Vutuv.Fediverse.Follower`: actor URI + inbox + sharedInbox) and answers
  with a delivered `Accept`; `Undo` removes it. Per-IP rate limited.
- **Deliveries** (`Vutuv.Fediverse.Delivery` + `Deliverer`): the same
  DB-backed queue shape as webhooks — rows per activity × distinct inbox
  (sharedInbox dedupes per server), drained every 15s or on nudge, POSTs
  signed with the member's key, exponential backoff (2, 4, 8 … minutes),
  dropped after 8 attempts or on 404/410. Test seam: `:fediverse_req_options`
  (Req plug), deliverer off in tests.
- **Post lifecycle** (hooks in `Vutuv.Posts` after commit): publishing a
  public post enqueues `Create(Note)`, editing `Update`, deleting
  `Delete(Tombstone)`; an edit that closes the audience federates a `Delete`
  too. Replies federate with `inReplyTo` only when the parent's author also
  federates (else the id would not resolve). Reposts do not federate (v1).
  The Note carries the member-rendered HTML with absolutized links, and image
  attachments via the public post-image proxy URLs. A public post's permalink
  answers an AP Accept with the Note (remote servers dereference ids).

## Visibility

- **The member** sees who follows them on `/settings/fediverse` (not just the
  count). The inbox captures each remote actor's `preferredUsername` and
  display name onto the `Follower` row (`handle`/`name`, cosmetic and
  truncated); `Fediverse.list_followers/2` returns the most recent, rendered
  as `@user@host` (`Follower.display_handle/1`, host from the actor URI)
  linking to the actor. This is **owner-only** — the public followers
  collection stays count-only, so the list lives in the private settings area,
  never under `/:slug`.
- **The operator** sees federation health on `/admin`: `Fediverse.stats/0`
  reports federating members (the SQL mirror of `federated?/1`), total remote
  followers, delivery-queue depth and how many rows are stuck (carry a
  `last_error`); the "Fediverse" dashboard card flags `attention` when a
  delivery run is stuck, and hides itself when `:fediverse_enabled` is off. The
  nightly Tagesbericht (`Vutuv.Reports`) counts new remote followers per Berlin
  day.

## Deliberate v1 limits

No inbound content (likes/replies/boosts are dropped), no `Announce` for
reposts, no `Move`/account migration, and account deletion sends no actor
`Delete` broadcast (rows cascade; remote copies age out). The followers
collection is count-only (privacy).
