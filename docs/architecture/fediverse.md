# Fediverse (follow-only ActivityPub federation)

People on Mastodon and other ActivityPub servers can follow an opted-in
member and receive their **public** posts. Federation is outbound-first by
design, and what comes back is accepted in two tiers, each with its own switch:
the **favourites and re-shares** people out there give a post, as their account
address and nothing else (issue #1068, on by default) and, behind a second and
deliberately separate opt-in, the **replies** they write under it (issues #1069
and #1071, off by default — that tier stores their words). The
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
  `.../outbox` (count-only collections) and `.../collections/featured` (the
  pinned post, see the post-lifecycle bullet below). The one URL that belongs to
  nobody in particular is `endpoints.sharedInbox` (issue #1073), which for the
  same reason lives under `/system/` rather than at a root word — see the
  shared-inbox bullet below. The actor also carries
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
- **Shared inbox** (`POST /system/inbox`, issue #1073): the same endpoint once
  for the whole installation, advertised as `endpoints.sharedInbox` in every
  actor document (`Docs.shared_inbox_url/0`), so a server with many followers
  here delivers a broadcast **once** instead of once per member it touches —
  the efficiency we already take advantage of on the way out, where the queue
  dedupes one row per distinct remote inbox. It is the same code: the same
  installation switch, the same blocklist checked first, the same per-IP limit,
  the same signature and anti-spoofing verification, and then the very same
  per-member handling. The per-member inbox keeps working forever; it is what
  every server already knows.

  The only thing that differs is where the addressees come from —
  `Vutuv.Fediverse.inbox_recipients/2` reads them out of the activity instead of
  the URL, from three places: the **addressing** (`to`/`cc`/`bto`/`bcc`/
  `audience` on the activity and its object, plus the object itself and, for an
  `Undo`, the object it wraps — a `Follow` names an actor URL, a `Like` a Note
  URL, a reply its `inReplyTo`, each of which hangs off the member it belongs
  to); the **remote actor's own `Update`/`Delete`**, which names no local member
  at all and is therefore fanned out to exactly the members that actor follows
  here (this is the case worth having the endpoint for — one account deletion
  used to be one signed delivery per member); and an author's `Update`/`Delete`
  **of a note they wrote**, fanned out to the members whose posts hold a copy.
  Addressee URIs are attacker-chosen text, so the list is cut at 25; the two
  lifecycle fan-outs are bounded by rows we wrote ourselves and are not.

  Two deliberate asymmetries. It never answers `404`/`410`: those belong to a
  URL that names one member, where a `410` is how a server learns *that account*
  is gone, so here a member who does not federate is simply no recipient and the
  delivery is acknowledged like any other — the endpoint cannot be used to ask
  who takes part. And the actor fetch that verification needs is signed with the
  key of the first addressee resolved from the still-unverified body (the
  per-member inbox uses the addressed member's key); it only ever picks a member
  the sender itself named, and the fetch goes back to the sender's own host.
  Recipients are resolved before verification because a key is needed for it,
  and acted on only afterwards, once the claimed `actor` is proven.
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
  `actor_uri`, `handle`, `kind`, `received_at` and **nothing else**. No display
  name, no avatar, no text: vutuv can never obtain consent from a stranger on
  another server, so what makes this lawful is storing almost nothing about them
  plus a deletion path that really works. The two stored identifiers are one and
  the same account address in two notations — `handle` is the actor document's
  `preferredUsername`, which the inbox has in hand anyway from the fetch that
  verifies the signature, so naming the account costs no extra request. The
  actor URI earns its place three times over: each person counts once (unique on
  `(post_id, actor_uri, kind)`), an upstream `Undo` finds its row, and the post
  can say who answered. `record_reaction/4` holds every gate in order — the
  installation switch, the member federates and has not switched reactions off
  (`users.fediverse_reactions?`, on by default, `/settings/fediverse`; switching
  it off calls `drop_reactions/1`), the object really is one of *their* public
  Note URLs, and the sender is within its inbound cap — and the inbox answers
  the same 202 whatever it decides, so a misdirected activity learns nothing.
  `remove_reaction/4` is deliberately **un**gated: an upstream withdrawal is the
  deletion path, so it must not depend on a switch still being on. Rows live
  exactly as long as the post (FK cascade, so a post delete and an account
  delete both take them), like a vutuv like; there is no separate expiry.
  - The counts **and the newest few accounts** ride the existing engagement
    select (`Vutuv.Posts.engagement_count_select/1` → `:fediverse_likes` and
    `:fediverse_reposts`, counted per verb, plus a `json_agg` of
    `:fediverse_reaction_actors`, capped at 4 rows), so all of it is batched
    with the other counters, ticks live through `{:post_counters, …}`
    (`broadcast_post_counters/1`) and reaches `VutuvWeb.AgentDocs.PostDoc`. The
    cap lives in SQL so a post with a thousand boosts cannot drag a thousand
    rows into a feed card; the counts stay the true totals behind the "+N more"
    tail.
  - **The card shows one number per act.** A favourite is a like and an
    `Announce` is a repost, so `Vutuv.Posts.shown_counts/1` adds the remote
    figures into the like / repost / reply counters the buttons print, and
    `PostDoc` carries the same folded `like_count` / `repost_count` /
    `reply_count`. The card used to print two sets of figures, the vutuv ones in
    the buttons and a permanent "from other networks" line under them: correct,
    and it read as bookkeeping — a reader had to add two columns in their head
    to learn how a post did.
  - **The split is one tap away, in an expandable panel** (`<details>`,
    collapsed, no JS): how many of the likes / reposts / replies arrived from
    out there, the accounts behind them, and the sentence that they are already
    counted above. So the transparency the separate line was for survives the
    folding — the reader can still see which world answered, and a hostile
    server can only inflate figures this panel labels as its own. Each account
    is a chip — the heart or re-share glyph the vutuv action bar uses for the
    same act, the `@handle@host` (`Vutuv.Fediverse.Handle`, shared with the
    follower list and the reply cards), linking **out** to the account, since
    there is no vutuv profile behind it. Public, like the counts always were:
    both acts are published under the actor's own name on their own server, and
    the reply cards below already name their authors the same way. The whole
    panel is hidden while every remote figure is zero, so a post nobody out
    there touched stays clean. The agent formats mirror it: the folded totals,
    then `fediverse_like_count` / `fediverse_repost_count` /
    `fediverse_reaction_count` / `fediverse_reply_count` and `fediverse_reactions`
    as the breakdown.
  - A new reaction also **notifies the author** (`fediverse_reaction`, the
    notification kind shaped exactly like `fediverse_reply`): derived straight
    from the reaction rows, so an `Undo`, a deleted post or the member switching
    reactions off deletes the notification with the row and there is no second
    place that has to remember to forget. Rows merge per post *and* per kind —
    a favourite and a re-share are different news.
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
  (`purge_instance/1`: that host's follower rows, its queued deliveries and the
  records of what was delivered there) and
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
- **Revocation** (issue #1102) — the one chokepoint every takedown goes through,
  because "taken down here" must not mean "still published there". See the
  section of its own below.
- **Post lifecycle** (hooks in `Vutuv.Posts` after commit): publishing a
  public post enqueues `Create(Note)`, editing `Update`, deleting
  `Delete(Tombstone)` through the one revocation chokepoint (`revoke_post/1`, see
  the revocation section); an edit that closes the audience revokes
  too. Replies federate with `inReplyTo` only when the parent's author also
  federates (else the id would not resolve). A **repost** of a public post
  enqueues an `Announce` to the reposter's own followers, un-reposting the
  matching `Undo(Announce)` (stable id `<note-url>#announce-<reposter>`); both
  fire only when the reposter federates and the **original author** federates
  too, since the `Announce` object is that author's Note id (issue #910).
  The Note carries the member-rendered HTML with absolutized links, and image
  attachments via the public post-image proxy URLs. A public post's permalink
  answers an AP Accept with the Note (remote servers dereference ids).
- **The pinned post** (issue #1110): the post a member pins to their profile
  is published as the ActivityPub **`featured` collection**, which is how
  Mastodon and friends show a pin at the top of the profile *they* render. The
  actor names it unconditionally (`"featured": <actor-url>/collections/featured`
  — an actor that only sometimes carries the field would make a remote profile
  depend on when it was last fetched), and `GET` on it answers an
  `OrderedCollection` whose `orderedItems` embed the **full Note**, the shape
  Mastodon serves, so no second fetch is needed. It is strictly the
  **anonymous public** view (`Fediverse.featured_posts/1` → `Posts.pinned_post(user, nil)`):
  the collection is served unauthenticated, so a pin that is restricted, frozen
  or otherwise not public is simply not in it, exactly as it is absent from the
  profile's `.md` sibling. Pinning also **pushes**: `Add { object: <note-url>,
  target: <featured-url> }` goes to every follower inbox so a remote profile
  updates right away instead of at its next actor refresh, releasing sends
  `Remove`, and replacing one pin with another sends both halves. Those two
  name different posts, so the remote end state is the same whichever arrives
  first — worth knowing, because the delivery queue drains concurrently and
  promises no order. A `Remove` fires even for a pin that
  was never public — a post that stopped being public must still be able to
  leave a remote profile — while an `Add` never does. Deleting the pinned post
  needs no `Remove`: the pin nulls itself in the database (`ON DELETE SET
  NULL`) and the post's own `Delete(Tombstone)` takes the remote copy with it.
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
  reactions switch, then — once on — the handle (with the shared
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
  `last_error`), how many servers are blocked and how many takedowns gave up
  without arriving (`failed_takedowns`, issue #1102); the "Fediverse" dashboard card
  flags `attention` when a delivery run is stuck, names the busiest inbound host
  and links to `/admin/fediverse`, and hides itself when `:fediverse_enabled` is
  off. That page is the blocklist plus `inbound_hosts/1` — what each remote
  server has stored here, biggest first, which is what a block decision is made
  from, plus the member takedown log and the undelivered-takedown list. The
  nightly Tagesbericht (`Vutuv.Reports`) counts new remote followers
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
## Revocation: a takedown has to leave the building

Until issue #1102 only one path federated a `Delete`: the owner pressing delete
on their own post. Everything else hid the content here and told the network
nothing — a report that froze a post, an admin's `remove_owner :deactivate`, the
strike ladder's permanent deactivation, and a reported reply from another network
whose origin never learned anybody had objected. Worse, the one path that did
federate was gated on `federated?/1`, which is false for a frozen, suspended or
deactivated account: the accounts moderation had already hidden were exactly the
ones whose deletions never went out.

**One chokepoint.** `Vutuv.Fediverse.revoke_post/1` sends the
`Delete(Tombstone)`, and every takedown calls it: `Vutuv.Posts.delete_post/1`, an
edit that closes the audience (`federate_post_update/1`), and the moderation
freezer (`Vutuv.Moderation.freeze_content/1`). `revoke_actor/1` is its
account-level twin for a **permanent** removal (`remove_owner :deactivate` and the
third strike), and `prepare_actor_delete/1` + `send_actor_delete/1` stay the
account-deletion path, which has to outlive the rows it reads.

**Gated on `ever_federated?/1`, not `federated?/1`** — the switch is on and the
member has an actor, i.e. copies of their posts may exist out there. Every
takedown runs at the moment the post or the account is hidden here, which is
precisely when `federated?/1` turns false; gating on it made the withdrawing
activities the only ones that never left. For the same reason there is no
`moved?/1` skip: a member who redirected their followers elsewhere stopped
*publishing*, but the servers that followed them still hold what came before.

**Addressed, not broadcast.** `Vutuv.Fediverse.PostDelivery`
(`fediverse_post_deliveries`) records each `(post, inbox, published Note id)`
when a `Create`/`Update` is enqueued, and the revocation reads it back. That
fixes two holes at once: delivery targets used to come from the follower table,
so a server that received the post and has since unfollowed kept its copy
forever; and the Tombstone id was built from the *current* username, so after a
rename (issue #1086) a delivered `Delete` matched nothing. An `Update` sent after
a rename publishes a second id, so the records are grouped by id and one `Delete`
goes out per id. A post with no records at all (published before the records
existed) falls back to the current follower inboxes and the current id — a worse
address than the real one, and a much better one than silence. The rows carry
**no foreign key** into `posts` on purpose: `delete_post/1` federates after the
commit, so a cascade would erase the addresses moments before they are needed.
They are cleared by the revocation that spends them, by
`drop_post_deliveries/1` in the account-deletion chokepoint, and by
`purge_instance/1`.

**A freeze is reversible, so it revokes and re-publishes.** Freezing a post hides
it from everyone but its owner, so leaving the remote copies up would make the
freeze a local fiction — `freeze_content/1` revokes. Lifting it (a rejected
report, or the owner editing the post) calls `republish_post/1`, which sends a
fresh `Create`: the other servers were told to delete the object, so there is
nothing left there for an `Update` to change. It re-reads the post rather than
trusting the caller's struct, whose `frozen_at` is still set (the unfreeze is an
`update_all`).

**A temporary hiding sends nothing at all.** No actor `Delete` for a week's
suspension, a profile freeze or an unconfirmed account, and no `410` either —
that stays reserved for the member's own opt-out (see the next section). A
three-day hiding must never read to the network as "this account is gone". A
profile freeze also deliberately does *not* fan a `Delete` out over every post
the member ever published: one report would then trigger a network-wide storm,
and a rejection a second one.

**Reports travel too.** Reporting a reply from another network
(`report_note/2`) deletes our cached copy *and* POSTs a `Flag` to the origin
actor's inbox — how these networks file a report with each other (Mastodon shows
an incoming `Flag` as a report). It is signed by the member whose post the reply
sat under, never by the reporter: a `Flag` is a signed statement, so it needs an
actor we serve a key for, vutuv has no installation-wide actor to file from, and
the thread's owner is the party that server already knows in this conversation.
Nothing in it names the reporter and no content rides along — the reported
object's own id is the whole reference, and the `content` line is a fixed English
sentence (read by a stranger's moderators, so not `gettext`). The reporter's daily
report cap bounds it, since the `Flag` only rides a successful takedown, and a
`"flagged"` row joins the `NoteEvent` ledger so an operator can tell a takedown
that only happened here from one the other server was told about. `remove_note/2`
— taking a reply off your own post — sends nothing: that is a decision about your
own page, not an accusation.

**An incomplete takedown is not silent.** A `Delete` or `Flag` that exhausts its
eight attempts is written to `Vutuv.Fediverse.DeliveryFailure` and listed on
`/admin/fediverse` ("Takedowns that did not get through", with the server, the
object and the last error), plus counted in `stats/0` as `failed_takedowns`. Only
the withdrawing types are recorded: a `Create` that never lands is one post that
did not travel, while a `Delete` that never lands means a copy somebody asked us
to withdraw is still published somewhere.

None of this is a guarantee. Remote deletion is advisory by protocol and always
will be, so the UI never claims a copy is gone — but every takedown now at least
asks.

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
symmetry `drop_reactions/1` already had for the reactions): those servers
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
shared inbox. And we now offer a shared inbox of our own (issue #1073), so the
asymmetry of asking other servers for an efficiency we did not give back is
gone; it is pure scale work, with no change to what any activity does. Every
takedown, not just the owner's own delete button, now asks the other servers to
withdraw the copy (issue #1102, the revocation section above).

## Following accounts on other networks (issue #1160)

Until 2026-07-26 this document recorded the opposite: reading other networks
inside vutuv was a stated non-goal, on the grounds that storing the post stream
of every followed account rebuilds what those networks' own clients already do
well. That decision was reversed. The reason it was made — a large, permanent
pile of third-party content with moderation and retention duties attached — did
not go away; it became the design brief, and the rest of the #1160–#1168 series
is where the answers live (a six-month clock on everything cached, the existing
report and takedown path extended to remote posts, the operator blocklist as
the floor under all of it).

This section covers the **subscription** half, which is all that #1160 ships:
who follows whom, and how the handshake works. What arrives afterwards is the
next issue's problem.

### The two tables

`fediverse_remote_accounts` is one row per remote actor that anybody here
follows: the actor URI (unique, the identity), the host it lives on, the
display strings, its inbox pair, its public key and its self-description as
plain text. One row however many members follow it, so a re-sync, a block purge
and later its cached posts all have one place to hang off.

`fediverse_follows` is the per-member relationship: member → remote account,
`state`, the id of the `Follow` we sent, and a `muted` flag with the same
meaning a local follow's mute has.

It is deliberately the mirror image of `fediverse_followers` (who out there
follows a member here), down to sharing the browse machinery: `browse_filters/1`,
`browse_per_page/0` and `VutuvWeb.BrowseTable` serve both tables, so a `?sort=`
value means the same thing on `/settings/fediverse/followers` and on
`/settings/fediverse/following`.

### The handshake

`Vutuv.Fediverse.follow_remote/2` takes anything people paste (`@you@server`,
`you@server`, a profile URL), resolves it to the account's canonical actor id
through WebFinger (`Vutuv.Fediverse.RemoteFollow.resolve_actor/1` — the same
SSRF-fenced, size-capped client the outward-facing subscribe dialog uses),
fetches the actor document through the usual signed GET, upserts the account and
writes the follow in state `requested`. Then a signed `Follow` goes into the
delivery queue.

The row says `requested` because that is the truth: an ActivityPub `Follow` is a
request, and an account that approves followers by hand may take days or never
answer. The UI shows "Requested" rather than "Following", and the count-only
`following` collection publishes **accepted** follows only — a request nobody
answered is not a relationship, and publishing it would leak what a member tried
to do.

An inbound `Accept` naming our `follow_activity_id` flips the state; a `Reject`
deletes the row (there is nothing left to show, nothing to retry, and keeping a
stranger's refusal on file earns nobody anything). Both are scoped to the actor
that answered, so one server can never settle a follow addressed to another.

### The gates

In the order they cost, because the cheap ones must run before the network is
touched:

1. **the member must federate** — the `Follow` is signed with their own actor
   key, so there is no such thing as an actorless follow. A member who has not
   opted in gets the explanation and the switch, not a redirect.
2. **the operator blocklist**, checked three times over one follow: on the typed
   host, on the resolved actor URL and on the canonical id the document claims,
   because each hop can land somewhere else than the last.
3. **an address on this very installation** is refused as `:local_account` and
   answered with a link to that member's profile. Following a vutuv member is a
   vutuv follow.
4. **an hourly budget** (`FEDIVERSE_REMOTE_FOLLOW_LIMIT`, the
   `claim_reply_budget/1` pattern), so a compromised account cannot walk a
   server's whole member list.
5. **a total ceiling** (`FEDIVERSE_MAX_REMOTE_FOLLOWS`), because every accepted
   follow is a standing invitation for another server to deliver here.

### Lifecycle

Unfollowing sends a best-effort `Undo(Follow)` carrying the original activity id
and deletes the row either way — it describes our member's intent, and they have
withdrawn it. Switching federation off does that for every follow
(`drop_remote_follows/1`, the `drop_followers/1` symmetry), gated on
`ever_federated?/1` rather than `federated?/1` for the reason revocation is: the
withdrawal happens exactly when the switch is already off.

An inbound `Update` of a remote actor re-syncs the stored account for everybody
who follows it; its `Delete` removes the account and, through the cascade, every
follow of it. Blocking an instance purges its accounts the same way it purges
its followers — a block is both ears and mouth shut, in both directions. And an
account `Delete` broadcast now also reaches the inboxes of the accounts the
member followed (`followed_inboxes/1`), so those servers stop delivering to an
inbox that no longer answers.

The profile feed of a member's *own* linked Mastodon/Bluesky accounts
(`Vutuv.SocialFeed`) remains a separate, unrelated thing: it shows the member's
own posts, on their own profile, at their own request.

### Their posts in the feed (issue #1161)

`fediverse_posts` is one row per remote post — **not** one per follower, since
several members can follow the same account and it is the same post — hanging
off the account. A `Create(Note)` from an actor with at least one **accepted**
local follow is reduced to plain text and stored by `perform_once/2` in the
inbox controller, which runs once per delivery rather than once per addressed
member.

What is refused is as much of the design as what is stored. A reply into
somebody else's conversation is dropped at the door (`own_thread?/2`): a
followed account's own thread is what a follower subscribed to, while their
reply under a stranger's post drags a third party's conversation into our
storage for the sake of one half of it. An audience narrower than public /
unlisted / followers is dropped too — a reply had to be kept in order to reach
the member it was addressed to, a post nobody here was published to has no such
claim. A `published` stamp in the future is clamped, so a server cannot pin
itself to the top of a feed forever.

Retention is the same "bounded copy" argument the replies make, minus the
freshness re-fetch: a followed account's stream is pushed to us continuously, so
an edit or a withdrawal arrives on its own, and re-asking about every cached post
of every account our members read would be far heavier than the per-reply check.
So: `FEDIVERSE_POST_RETENTION_DAYS` (183) as the ceiling, an upstream
`Update`/`Delete` honoured at once, purged when the last follow of the author
ends, gone with the accounts on an instance block.

The feed reads it as a **fourth source** in `Vutuv.Posts.feed_page/2`, merged on
publication time. `decorate_feed_entries/2` splits the remote entries off before
the local pipeline (they are not `%Post{}`, have no thread, no reposters and no
engagement) and merges them back on `at`. A muted follow leaves the feed and
keeps the subscription; a followers-only post reaches only a member whose own
follow is accepted.

One thing worth remembering about the report path: there is **one** cached row
per post, shared by everybody following its author, so one member's report
deletes it out of all of their feeds. That is why the card leads with Mute — the
private, reversible lever — and why the confirmation says so.

### The account page (issue #1162)

`/system/fediverse/account/:id` (`VutuvWeb.FediverseAccountLive`) is where every
remote handle now points: reaction chips, remote reply cards and remote feed
cards link inward when we know the account and straight out when we do not.
Signed-in only and `noindex` (the `:noindex_pipe` pipeline), keyed by the **row
id** so the page is no open-ended fetch surface, and it fetches nothing on view.

Which means account rows have to exist for more than just followed accounts:
`remember_remote_account/1` keeps the actor document the inbox already fetched
and verified whenever a reply or a reaction from that actor is stored. That
would otherwise grow into a directory of everybody who ever touched the
installation, so `purge_unreferenced_remote_accounts/0` (hourly, in the sweeper)
drops every account with no follow, no cached post, no stored reply and no
stored reaction.

The page is a **follow surface plus a preview**, not a mirror profile: identity,
self-description (clamped), follow / requested / mute state, the cached posts
capped at 30, and "View their full profile on <host>" in every state. It is also
the only place a **muted** account can still be reached, which is why unmute
lives here — muting from the feed removes that account's posts, and with them
the menu that muted it.
