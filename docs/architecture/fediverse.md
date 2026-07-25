# Fediverse (follow-only ActivityPub federation)

People on Mastodon and other ActivityPub servers can follow an opted-in
member and receive their **public** posts. Federation is outbound-first by
design, and what comes back is accepted in two tiers, each with its own switch:
a bare **count** of favourites and re-shares (issue #1068, on by default) and,
behind a second and deliberately separate opt-in, the **replies** people out
there write under a member's post (issues #1069 and #1071, off by default). The
inbox otherwise processes only `Follow`, `Undo(Follow)`, the remote actor's own
lifecycle (`Update` / `Delete`) and an author's `Update`/`Delete` of a reply they
sent us; everything else is acknowledged (202) and dropped. Everything lives in
`Vutuv.Fediverse`.

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
  Deliveries to a gone inbox are dropped by the queue on 404/410; the follower
  row behind them is dropped by the pruner below.
- **Pruning followers who left silently** (issue #1072,
  `Vutuv.Fediverse.FollowerPruner` + `prune_due_followers/1`): an `Undo(Follow)`
  or the remote's own `Delete` removes a follower at once, but a server that
  simply stops answering for one account tells us nothing — deliveries go to its
  *shared* inbox, which keeps working for everybody else there, so pruning on a
  failed delivery would wrongly drop that whole server. Instead each follower row
  is re-fetched on a slow rotation with the SSRF-guarded, size-capped, signed
  `fetch_remote_actor/2` and removed **only** on `404` or `410` (what the common
  implementations answer for a deleted account). A timeout, a connection error, a
  `5xx`, a `429` or a redirect leaves the row alone and only stamps
  `fediverse_followers.last_checked_at` — the server is having a bad day, not a
  person leaving. Bounded three ways so a big server is never hammered: one row
  is re-checked at most every `prune_recheck_days/0` (30), a run takes at most
  `prune_batch/0` (50) rows and at most 10 of them from any one host, and the run
  is hourly. Each removal appends one row to `fediverse_follower_prunes`
  (`Vutuv.Fediverse.FollowerPrune`) carrying the member, the **host** and the
  status — deliberately *not* the remote actor URI, since not holding an
  identifier of somebody who deleted their account is the entire point. The
  nightly Tagesbericht counts them (`Vutuv.Reports`, "Entfernte
  Fediverse-Follower"), so a mass-prune is visible the next morning rather than
  silent. Gated by `:fediverse_follower_pruning` (off in tests) on top of
  `:fediverse_enabled`.
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
- **Replies from other networks** (issues #1069 and #1071, the first content
  vutuv stores that its own members did not write): a `Create(Note)` whose
  `inReplyTo` names one of a member's public posts becomes a row in
  `fediverse_notes` (`Vutuv.Fediverse.Note`). `record_reply/3` holds the gates in
  order — the installation switch, the member federates, the member switched
  **replies** on (`users.fediverse_replies?`, **off** by default, its own switch
  beside the counts because a counter row says nothing about a person while a
  sentence with their name on it does), the Note answers one of *their own*
  posts, the post is public, the sender is within its inbound cap, and there is
  text left once the markup is gone. Same 202 whatever it decides.
  - **Plain text, never HTML.** `Vutuv.RemoteHtml.to_text/2` (shared with the
    Mastodon profile feed, so remote HTML is reduced exactly one way) drops
    `<script>`/`<style>` **with their contents**, turns `<br>`/`</p>` into line
    breaks, strips every remaining tag, decodes the base entities once and
    clamps. So nothing a stranger wrote is ever rendered `raw`, the agent-format
    siblings carry the value unchanged, and the cap is well defined. **No avatar
    is copied**: the card renders initials and links to the origin.
  - **Audience** (issue #1071), read from `to`/`cc` on both the Create and the
    Note, handling all three spellings of the public collection. Only `"public"`
    is public; `"followers"`, `"direct"` and `"unknown"` render to the addressed
    member alone, signed in, on their own post, behind the same 🔒 a restricted
    post wears plus "sent to you only". Never widened, and there is deliberately
    **no** button to publish one: we can never ask the author of a private
    message whether that would be alright. `list_notes/2` is the one
    viewer-scoped read, so no call site can forget the rule; `PostDoc` takes
    public notes even on the authenticated `viewer:` path, so a private reply
    cannot leave through `/api/2.0` or a `.json` sibling; and the public count
    (`engagement_count_select` → `:fediverse_replies`) counts public notes only,
    or the figure itself would leak that a private message exists.
  - **Retention is two layers.** The ceiling is `expires_at`, six months out
    (`:fediverse_note_retention_days`), swept hourly by
    `Vutuv.Fediverse.NoteSweeper` — the promise that holds whatever else fails.
    Under it a **lazy on-view freshness check**: rendering a note whose
    `checked_at` is older than a week (`:fediverse_note_refresh_days`) queues an
    SSRF-vetted `refresh_note/1` in a task, so no render waits on a stranger's
    server. `200` and still public refreshes the text **and pushes the ceiling
    out**; `404`/`410`/`403`, or an audience narrowed away from public, deletes
    at once; anything else changes nothing, so an offline server buys no
    retention and an outage triggers no mass delete. Net effect, and the reason
    "cache" is an honest word here: a reply people keep reading tracks its
    original, one nobody has opened in six months is collected. **Non-public
    notes are never re-fetched** — a direct message answers 403/404 to any fetch
    we can make, which the checker would read as "deleted upstream" and act on,
    and asking would tell the origin we hold it. They live by the ceiling and an
    upstream `Delete` alone.
  - **Takedown, with no workflow.** The member removes a reply from their own
    post; anyone who can see it reports it, which **deletes it immediately** —
    no case, no freezer, because unlike a member's own post this is a cache of
    something that still exists at its origin. Both write one
    `Vutuv.Fediverse.NoteEvent` row, which keeps **no content and no URIs**
    (following `FollowerPrune`, #1072): action, host, a keyed HMAC of the actor
    URI, who acted, when. That is enough for the only decision it serves — one
    troll or the whole server — without holding an identifier of somebody whose
    words we just deleted. Reports are rate limited per reporter. Automatic
    deletions are **not** logged per row (an expiry run would drown it); they go
    to the log in aggregate.
  - Everything else that deletes: the post, the account (both by FK cascade),
    `purge_instance/1` when the server is blocked, and switching the opt-in off
    (`drop_notes/1`) — the switch is a delete lever, not a display toggle.
  - **Where it shows.** Woven into the permalink's conversation as an ordinary
    sibling in time order (`VutuvWeb.PostLive.Thread` +
    `PostComponents.remote_reply_card/1`), wearing its own skin so the two worlds
    are told apart without colour: a **slate** initials tile with the 🌐 badge,
    a **dashed** left rail against the solid connector rail, the name as plain
    text beside a `@handle@host` that links out, and **no action bar** (liking a
    note on someone else's server is not a thing that exists). A content warning
    renders as a closed lid. The member also gets a notification: the
    `fediverse_reply` kind, sourced **straight from the notes table**, so
    deleting a note deletes its notification with no second place to remember.
- **Answering a reply that came from another network** (issue #1070, the one
  place a member's own action makes vutuv POST to a server that never followed
  them): the "Reply" link on a remote reply's card opens
  `/system/fediverse/reply/:id` (`VutuvWeb.PostLive.RemoteReply`) — the reply
  above, the ordinary post composer below, and a line stating plainly, *before*
  the member types, that the answer goes to that person on their own server and to
  the member's Fediverse followers and is a public vutuv post as well. Nobody
  should publish to another network by accident.
  - **Underneath it is an ordinary reply.** `Posts.create_remote_reply/3` writes
    the same `PostReply` row to the vutuv post the note answers, so local
    threading, the parent-author notification, the public reply count and the edit
    window are untouched, plus a `Vutuv.Posts.PostRemoteReply` sidecar recording
    the *other* thing it answers. The conversation renderer reads that sidecar to
    hang the answer **under** the remote card rather than beside it (the forest
    would otherwise make them siblings).
  - **The sidecar carries its own copy of the target** — `in_reply_to_uri`,
    `actor_uri`, `inbox_uri`, `handle` — because a note is a cache that expires
    six months out or is taken down before that, while the member's answer lives
    on and an `Update`/`Delete` still has to reach the person answered. `note_id`
    nilifies for that reason instead of cascading. The inbox itself was captured
    when the note was stored (the inbox had already fetched and verified that
    actor document to check the signature), so answering costs no network call.
  - **The activity**: `inReplyTo` is the remote note's own id, not the vutuv post
    underneath (that note already points back at our post, so this is what threads
    the answer correctly over there); the answered actor joins `cc` beside the
    usual public audience; and a `Mention` tag plus a leading linked `@user@host`
    in the outgoing HTML is what gets them notified. The `Mention` is built from
    the **stored** actor URI, never parsed out of the member's typed text — parsing
    would let anyone mint a verified-looking Mention at an actor nobody checked,
    which is mention spam with our signature on it. The handle is added on the wire
    only: on vutuv the answer shows a "Replying to" line, so a member who has never
    heard of Mastodon never types a handle in a foreign format.
  - **Who may answer**: any member who federates, not only the author of the post
    the note sits under — the conversation is on their post either way, and the
    answer is delivered from the answerer's own actor to their own followers.
    `Fediverse.check_remote_reply/2` holds the gates and **names** which one
    refused, because `:not_federating` is the one the member can act on: the page
    turns it into an explanation and a link to `/settings/fediverse` rather than a
    dead end. Hiding the link from them instead would leave them no way to find out
    the capability exists.
  - **Public replies only** in v1, and the operator blocklist stops answers going
    to a shut-out server (a block is both ears and mouth shut). Plus an hourly
    per-member budget (`:fediverse_outbound_reply_limit`, 30) as the backstop
    against a compromised account relaying: the shape of the feature already bounds
    it hard, since an answer needs a stored reply on a vutuv post first, so the
    targets are people who wrote here and never a list an attacker picks.
  - **The inbox is vetted twice.** An actor document names its own inbox and
    whoever runs that server writes the document, so a hostile one can point its
    inbox at a third party and turn a member's answer into a signed POST there (the
    classic ActivityPub inbox redirect). `Fediverse.own_inbox/1` therefore refuses
    an inbox that is not https on the actor's **own host** before it is ever
    stored — the same rule the inbox already applies to a signature's `keyId` — and
    `attempt/2` re-checks every row at send time (https, not internal, not
    blocked).
- **Holding a post back until its pictures are vetted** (issue #1070): a post's
  images are invisible until the AI scan releases them
  (`Vutuv.Moderation.ImageScans`), so a Note built the instant the post commits
  carries no attachment for them and nothing would ever send the picture. Such a
  post is now enqueued with a short hold and a `rebuild_from` marker
  (`fediverse_deliveries`), and the deliverer re-renders it when it goes out.
  `Fediverse.images_settled/1`, called from
  `Vutuv.Moderation.ImageSubjects.apply_approved/1` **and** `apply_rejected/1`
  (a rejected picture settles the post just as an approved one does — it then
  federates without it, which is what vetting first means), pulls the row forward
  the moment the last picture on the post has a verdict, which is the normal case
  and usually a few seconds. `:fediverse_image_hold_seconds` (90) is the
  **ceiling**, not the usual wait: it is what happens when the scanner is down, and
  then the post goes out without the unvetted picture rather than not at all.
  `activity_json` still holds a complete, valid activity for a held row, so a
  release that knows nothing of `rebuild_from` delivers that instead of choking —
  the worst a deploy window can do is federate one post without its picture. The
  rebuild re-checks the gates too, so a post deleted or made non-public during the
  hold never goes out.
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
- **The profile** (issue #1081) is where everyone else finds out. A federating
  member's `/:slug` carries a **Fediverse card**: the handle `@member@vutuv.de`
  with a copy button, and the "Follow from your own server" field described
  below. It is the one card written for a visitor who is not a member, and it
  renders for nobody else (no opt-in, no card; installation switch off, no
  card). A member who moved their account away
  (`moved_to`) sees the forwarding address in its place, since the old handle
  now only answers with a redirect. `ProfileDoc` carries the same facts into
  the agent formats.
- **The member** sees who follows them (not just the count). The inbox captures
  each remote actor's `preferredUsername` and display name onto the `Follower`
  row (`handle`/`name`, cosmetic and truncated), rendered as `@user@host`
  (`Follower.display_handle/1`, host from the actor URI) linking to the actor.
  `/settings/fediverse` shows the five newest as a taste; the whole list is its
  own page, **`/settings/fediverse/followers`**
  (`VutuvWeb.FediverseFollowersLive`), because a flat list reads fine at four
  followers and not at all at ten thousand. That page is a table with
  search-as-you-type (display name, handle, server, or a whole `@user@server`
  handle pasted out of a Mastodon profile — matched as two facts, not one
  substring), a server filter that every row's server name also sets in one
  click, three sortable columns (Account / Server / **Following since**, the
  `inserted_at` the flat list never showed) and numbered paging. Filter, sort
  and page live in the URL (`push_patch`), so a view is shareable and the back
  button restores it. The query work is `Fediverse.follower_filters/1` +
  `count_followers/2` + `list_followers_page/4` + `follower_hosts/2`, all scoped
  to the member's own rows first; every sort tiebreaks on the row id (UUID v7,
  so arrival order at sub-second resolution, where `inserted_at` only has
  seconds), so offset paging is stable. This is **owner-only** — the public
  followers collection stays
  count-only, so the list lives in the private settings area, never under
  `/:slug`.
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

## Follow from your own server

Handing out a handle only gets a visitor halfway: they still have to switch
apps, paste it into a search box and wait. The Fediverse's answer is the
**remote-follow (OStatus subscribe) template**, which every server publishes in
its own WebFinger document. So the profile card asks the visitor for *their*
address, `Vutuv.Fediverse.RemoteFollow` looks up *their* server's follow dialog
and `VutuvWeb.RemoteFollowController` (`POST /:slug/fediverse/follow`) redirects
them into it with the member's `acct:` URI filled in. The follow is then
confirmed where the visitor's account actually lives; no credential ever reaches
vutuv and the typed address is used for one lookup and forgotten.

    GET https://their.server/.well-known/webfinger?resource=acct:them@their.server
    -> links: [{"rel": "http://ostatus.org/spec/1.0#subscribe",
                "template": "https://their.server/authorize_interaction?uri={uri}"}]

It is a plain HTML form post, not a `phx-click`: the person it is for arrives
from another network and is the last visitor whose JavaScript we should assume
anything about. (The profile is a LiveView, which loads the session's CSRF state,
so the token the form stamps is valid from a live render too.)

This is also the **only outbound fetch an anonymous visitor can trigger**, so it
is fenced like the inbox path it borrows its shape from: the installation switch
plus the member actually federating (a crafted POST to a non-federating member is
refused), a rate limit per IP (`VutuvWeb.RateLimit`, 20/h), https only, the host
vetted against `Vutuv.Ssrf` before the request **and again** after the single
redirect hop that is allowed (the common apex-to-server WebFinger setup — Req's
own redirect following would skip that second check), short timeouts, no
retries, and a body ceiling that halts the stream rather than buffering. Every
failure lands back on the profile with a plain-language flash naming the server,
and the handle is right there to copy, so there is always a way through.
## Leaving: 410 Gone, and saying so first

Switching the opt-in off used to make every actor endpoint answer `404`, which
remote servers shrug off — they kept the account and its copies of the member's
posts indefinitely. Now `Vutuv.Fediverse.departed?/1` (took part once, the
keypair is still here, opt-in now off) makes the actor, its collections, its
inbox, WebFinger and the AP-negotiated profile URL answer **`410 Gone`**
(`VutuvWeb.FediverseController.refuse/2`, shared with `UserController`). Mastodon
& co. read a `410` on an actor they know as "this account was deleted" and purge
the account **and its copies of that account's posts**: the closest the protocol
comes to honouring "forget me", and the passive twin of the pruner above (which
reads exactly that answer from the other side).

Which is why `410` is **only** the member's own departure. Everything else keeps
answering `404`: a member who never federated (nothing to forget), the
installation switch being off (an operator decision must not erase members'
remote presence), and every *temporary* hiding — frozen, suspended, deactivated,
unconfirmed. A three-day suspension must never tell the network to delete the
account.

Because leaving now really does ask other servers to forget the member,
switching off also **drops their follower rows** (`drop_followers/1`, the
symmetry `drop_reactions/1` already had for the reaction counts): those servers
drop the follow at their end, so a kept row would only be a relationship that
exists nowhere else.

And because neither direction can be taken back, the switch **asks first**. The
words live in one place, `VutuvWeb.SettingsHTML.fediverse_consent_notice/1`, and
are shown twice: as a modal on `/settings/fediverse` (the `fediverseConsent`
enhancement in `app.js` intercepts the submit, and its confirm button sets the
`fediverse_ack` field) and, for a browser without JavaScript, as the full-page
`fediverse_confirm.html.heex`, which replays the submitted fields plus the
acknowledgement. `SettingsController.update_fediverse/2` requires that
acknowledgement whenever the submit actually flips the switch, so it can never
flip unacknowledged; a save that only touches the other settings on the page
passes straight through. What the words say is what vutuv cannot do: a delivered
post is beyond reach for good, and leaving is a request to those servers, not a
guarantee.

## Deliberate v1 limits

Inbound **reply text** is stored now (issues #1069 and #1071, see the bullet
above) under the agreed retention model: counts before text, a counter row lives
as long as its post, stored remote text expires after six months unless its
origin confirms it is still published. Still dropped: **avatars** (initials and
a link out instead), **boost rosters** (who re-shared stays a number), inline
**images** in a remote reply, and replies that answer another *remote* reply
rather than a vutuv post — that conversation lives on its author's server, and
following it would mean storing arbitrary third-party threads.

Replying **back** to somebody on another network is built now (issue #1070, see
the outbound-replies bullet above) — for **public** replies only. A reply
addressed to the member alone still cannot be answered: answering it publicly
would publish half of an exchange its author asked to keep to one person, and
answering it privately would mean a new kind of vutuv post that has to be
invisible in the feed, on the profile, in the thread, in the agent formats and in
the data export. That is its own feature; the card links to the original instead.

The operator blocklist and the
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
collection is count-only (privacy). Followers who leave without saying so are
found now (issue #1072) — the hourly re-check above prunes a row only on a
`404`/`410` from the actor document itself, never on a failed delivery to a
shared inbox.

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
