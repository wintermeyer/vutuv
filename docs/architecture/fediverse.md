# Fediverse (follow-only ActivityPub federation)

People on Mastodon and other ActivityPub servers can follow an opted-in
member and receive their **public** posts. Federation is outbound-first by
design: no remote posts or reply text is stored. The one thing that does come
back is a **count** (issue #1068) — how many people out there favourited or
re-shared a post — and even that is a bare counter row. The inbox otherwise
processes only `Follow`, `Undo(Follow)` and the remote actor's own lifecycle
(`Update` / `Delete`); everything else is acknowledged (202) and dropped.
Everything lives in `Vutuv.Fediverse`.

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
  `.../outbox` (count-only collections). The actor also carries
  **`alsoKnownAs`** (issue #986) — the account URIs a member is migrating
  *from* (`users.also_known_as`, set on `/settings/fediverse/move`, one per line).
  A remote server that moves a member's followers *to* vutuv checks this before
  it accepts the move (the destination must name the origin as an alias first).
  Anyone can *claim* an alias, so verifying it is the remote server's job;
  vutuv only publishes the claim, and the key renders only when non-empty. A
  member who instead moves *out* sets **`movedTo`** (`users.moved_to`):
  `Vutuv.Fediverse.move_out/2` fetches the target actor, confirms it lists this
  member in *its* `alsoKnownAs` (the same check every remote server makes, so a
  doomed Move fails fast), stamps `moved_to`/`moved_at`, and broadcasts
  `Move { actor, object, target }` to every follower inbox. From then on the
  member's posts stop federating (`moved?/1` gate) while the actor keeps serving
  the `movedTo` redirect; the vutuv profile is untouched (a redirect, not a
  deletion). A 30-day cooldown (`move_cooldown_days/0`) stops move-spam, and
  `cancel_move/1` clears the redirect while keeping `moved_at` so the cooldown
  still holds.
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
- **Remote actor lifecycle**: an `Update` of the actor itself re-syncs the
  stored row from the freshly fetched document (a renamed remote must not stay
  listed under the old handle, a moved inbox must not keep receiving posts) and
  a `Delete` of the actor itself removes it, so a gone account stops counting
  as a follower. Both are scoped to the actor: `Update`/`Delete` of a remote
  *note* still falls through and is dropped, and an `Update` from someone who
  follows nobody here never mints a row. The `Delete` half is best effort by
  protocol — a server that already purged the account answers our actor fetch
  with 410, so the signature cannot be verified and the activity is rejected;
  it lands during the window where the account is suspended but still served.
  Deliveries to a gone inbox are dropped by the queue on 404/410 but do not
  yet prune the follower row (see the v1 limits).
- **Reactions from other networks** (issue #1068, the one inbound thing that is
  stored): a `Like` or `Announce` naming a member's public Note becomes one row
  in `fediverse_reactions` (`Vutuv.Fediverse.Reaction`) — `post_id`,
  `actor_uri`, `kind`, `received_at` and **nothing else**. No display name, no
  avatar, no text: vutuv can never obtain consent from a stranger on another
  server, so what makes this lawful is storing almost nothing about them plus a
  deletion path that really works. The actor URI earns its place twice over:
  each person counts once (unique on `(post_id, actor_uri, kind)`) and an
  upstream `Undo` can find its row. `record_reaction/4` holds every gate in
  order — the installation switch, the member federates and has not switched
  the counts off (`users.fediverse_reactions?`, on by default, `/settings/
  fediverse`; switching it off calls `drop_reactions/1`), the object really is
  one of *their* public Note URLs, and the sender is within its inbound cap —
  and the inbox answers the same 202 whatever it decides, so a misdirected
  activity learns nothing. `remove_reaction/4` is deliberately **un**gated: an
  upstream withdrawal is the deletion path, so it must not depend on a switch
  still being on. Rows live exactly as long as the post (FK cascade, so a post
  delete and an account delete both take them), like a vutuv like; there is no
  separate expiry. The count rides the existing engagement select
  (`Vutuv.Posts.engagement_count_select/1` → `:fediverse_reactions`), so it is
  batched with the other counters, ticks live through `{:post_counters, …}`
  (`broadcast_post_counters/1`) and reaches `VutuvWeb.AgentDocs.PostDoc` as
  `fediverse_reaction_count`. It renders as its **own** labelled line under the
  vutuv counters, never folded into them: a hostile server can then inflate
  only its own line, and the reader sees which world answered. Public and
  hidden at zero.
- **The operator's safety floor** (issue #1067): anyone can run an ActivityPub
  server, so before anything a remote sends is stored, two independent levers
  sit in front of it. The **blocklist**
  (`Vutuv.Fediverse.BlockedInstance`, `fediverse_blocked_instances`, admin UI at
  `/admin/fediverse`) shuts one named host out: the inbox checks it **first** —
  before the signature is verified and before the remote actor document is
  fetched, against *both* the signature's `keyId` and the activity's claimed
  `actor`, since neither is verified yet — and answers `202` rather than `403`,
  so the list is not enumerable from outside. Blocking is also a purge
  (`purge_instance/1`: that host's follower rows and its queued deliveries) and
  a mouth-shut: `deliver_due/0` drops a queued delivery to a blocked host, and
  since the follower rows are the delivery targets, the member's posts stop
  going there. Unblocking resurrects nothing. The **caps**
  (`check_inbound_cap/1`, `Vutuv.RateLimiter`, `FEDIVERSE_INBOUND_CAPS`, default
  600 rows/hour per host and 60 per remote actor, host bucket hit first so a
  flooder cannot also plant one bucket per forged actor) bound the servers
  nobody has thought to block yet; a capped write returns
  `{:error, :inbound_capped}` and the inbox drops it silently. Both are behind
  `:fediverse_enabled`, so an intranet installation has neither screen nor rows.
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
  federates (else the id would not resolve). A **repost** of a public post
  enqueues an `Announce` to the reposter's own followers, un-reposting the
  matching `Undo(Announce)` (stable id `<note-url>#announce-<reposter>`); both
  fire only when the reposter federates and the **original author** federates
  too, since the `Announce` object is that author's Note id (issue #910).
  The Note carries the member-rendered HTML with absolutized links, and image
  attachments via the public post-image proxy URLs. A public post's permalink
  answers an AP Accept with the Note (remote servers dereference ids).
- **Account deletion** (`Vutuv.Accounts.delete_user/1`, issue #985): a
  federating member's followers are told their actor is gone with an actor
  `Delete { object: <actor-url> }`. The follower rows *are* the delivery
  targets and the actor row holds the signing key, and both cascade away the
  instant the delete commits — so `Fediverse.prepare_actor_delete/1` reads the
  inboxes and key **before** the transaction into a self-contained payload, and
  `send_actor_delete/1` signs and POSTs it (concurrent, best effort, bounded)
  **after** the account is gone. A failed or timed-out POST never blocks or
  reverses the deletion; a member who never federated captures nothing. This is
  the outbound mirror of the inbound remote-`Delete` handling above — a
  courtesy, never a guarantee (remote deletion is advisory by protocol).

## Visibility

- **The member's two pages.** `/settings/fediverse` answers one question for
  someone who has never heard the word: do I take part at all. Plain-language
  explainer, the three things that happen if you do, the on/off switch, the
  reaction-count switch, then — once on — the handle (with the shared
  `data-copy` button, since copying it is the action people come for) and who
  followed. **`/settings/fediverse/move`** holds account migration, **both
  directions on one page** (`Umzug zu vutuv` = the `alsoKnownAs` aliases,
  `Umzug weg von vutuv` = the `Move` broadcast + cancel), reached by a quiet
  link and only while federating. They used to share the main page, where a raw
  actor-URI textarea sat between the switch and Save — a tax on everyone who
  will never move accounts — and where the two directions, 300px apart, read as
  the same thing. Every move action redirects back to that page, so the state
  change lands on screen.
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
  followers, delivery-queue depth, how many rows are stuck (carry a
  `last_error`) and how many servers are blocked; the "Fediverse" dashboard card
  flags `attention` when a delivery run is stuck, names the busiest inbound host
  and links to `/admin/fediverse`, and hides itself when `:fediverse_enabled` is
  off. That page is the blocklist plus `inbound_hosts/1` — what each remote
  server has stored here, biggest first, which is what a block decision is made
  from. The nightly Tagesbericht (`Vutuv.Reports`) counts new remote followers
  per Berlin day.

## Deliberate v1 limits

No inbound **content** — remote reply text, names, avatars and boost rosters are
all still dropped. Only the reaction *count* is stored (issue #1068, above); the
rest of the inbound tier is planned in issues #1069–#1071 under the agreed
retention model: counts before text, a counter row lives as long as its post,
stored remote text expires after six months. The operator blocklist and the
inbound caps that were the condition for storing anything shipped alongside it
(issue #1067, see the safety-floor bullet above). Reposts
now federate as
`Announce` (issue #910) and account deletion broadcasts an actor `Delete`
(issue #985) — see the post-lifecycle and account-deletion bullets.
Account migration is **both ways** now (issue #986):
`alsoKnownAs` moves followers *in*, `Move` + `movedTo` moves them *out* (see the
Actor bullet above). The design choice worth remembering: a move-out is a
**redirect, never a deletion** — the vutuv account is a full profile, not just a
Fediverse actor, so moving your Fediverse followers away only pauses outbound
post federation and publishes the redirect; the profile, CV and everything else
stay. Deleting an account remains its own separate action. The followers
collection is count-only (privacy). A follower row whose inbox answers 404/410
is not pruned either: deliveries go to the sharedInbox where the remote
declares one, so a per-actor gone signal rarely reaches us and pruning on a
shared inbox would drop every follower on that server (issue #1072).

## Non-goal: reading other networks inside vutuv

Members following Fediverse accounts and reading their posts in the vutuv feed
is **not planned** (decided 2026-07-24). It would mean continuously storing the
post stream of every followed remote account — a large, permanent pile of
third-party content with the moderation and retention duties that come with it —
to rebuild what the clients of those networks already do well. vutuv publishes
outward and (once the inbound tier lands) shows the response to what its members
published; it is not a reader for other networks. The existing profile feed of a
member's *own* linked Mastodon/Bluesky accounts (`Vutuv.SocialFeed`) is a
different thing: it shows the member's own posts, on their own profile, at their
own request.
