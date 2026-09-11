# The social graph

A follow is the only relationship primitive; being connected ("vernetzt") is
derived from two mutual follows. Everything lives in `Vutuv.Social`.

## Follow + connect

One action, two readings (`Vutuv.Social`). A **follow** (`Vutuv.Social.Follow`,
table `follows`) is the only relationship action: a one-directional subscription
— follow anyone, no approval — that decides whose posts reach your `/feed`.

Two people who follow **each other** are **vernetzt** (connected), derived from
the two follow edges (`Vutuv.Social.connected?/2`), not a separate record — so
there is no request / accept / decline / cooldown.

A follow-back pushes a live "you are now connected" notification; the profile
header carries the `<.follow_button>`, an inert "✓ Vernetzt" status when the
follow is mutual, and a `<.mute_button>` once you follow the member.

`/:slug/connections` lists a member's vernetzt people (the owner ends a
connection by unfollowing).

The three profile-header counts come from the tagged count queries behind
**`Social.social_counts/1`** (one union round trip; the single accessors
`follower_count/1` / `followee_count/1` / `connection_count/1` share the same
query builders, so the gates cannot drift). On a profile mount
`Social.profile_count_queries/1` hands the three arms to
`UserProfileLive.count_loads/2`, which runs each as its **own statement,
side by side** with the nine section totals (those stay one union) and the
viewer-scoped posts total (`Posts.author_timeline_count_query/2`). They were
one 13-arm union per mount, which read as one round trip and cost 10–25 ms
of it: a plan that wide is re-planned for its first executions on every pool
connection and lands on a Parallel Append whose worker launch is the price
(measured 2026-09-05 on the production copy — the union 9–13 ms, its arms
in a row 6 ms, side by side 1.8 ms). The same mount runs the counts, the
section preloads and the Beiträge card side by side as well
(`load_profile/1`, through `Vutuv.Concurrent`, four at a time), which halved
the profile's DB critical path.
Two indexes carry the load: the covering visibility index
`users_visible_covering_index` (`(id) INCLUDE (suspended_until)` on the
public-visibility predicate) serves the counts' users gate index-only
(14.3ms → 1.0ms on the production copy), and the
`follows_(follower|followee)_recency_index` composites
(`(side_id, inserted_at DESC, id DESC)`) let the header's newest-3
follower/following previews (`Follow.latest/2`) stop at the first
gate-passing rows instead of sorting the member's whole follow set; the old
single-column follows indexes were dropped as redundant prefixes.

**Mute** is a per-follow flag (`follows.muted`, `<.mute_button>` → PUT
`/follows/:id/mute`): a muted follow keeps the relationship and any vernetzt
status but drops the followee's posts out of *your* feed — silent and
one-directional, unlike a block.

**Muting an account you do not follow** is the table beside it, `account_mutes`
(`Vutuv.Mutes`): the account a reader wants gone is usually one they never
followed — somebody they *do* follow keeps boosting or resharing it — and a flag
on the follow edge has nowhere to live for that. A row names the reader, exactly
one target (member, page, or remote account, CHECK-enforced) and a **scope**:

* `:all` — nothing this account writes reaches the feed, whoever passes it on.
* `:reposts` — only what it **passes on** is dropped; its own posts stay. This
  is the scope that names an account the reader follows on purpose.
* `:reposts_of` — the same complaint about the **author**: what anybody passes
  on *of* this account is dropped, its own posts stay. This is what a boost
  banner actually raises — the account being handed around is one the reader
  never chose, and silencing the messenger holds only until the next member
  boosts the same account.

The two narrow scopes are opposite ends of one card: `:reposts` names the
account on the "Reposted by" line, `:reposts_of` the author under it.
`Mutes.repost_author_scopes/0` is the pair every source asks for where somebody
else does the carrying (`[:all, :reposts_of]`), so a fourth such query cannot
read half the answer. One row per reader and account, so the three are
alternatives rather than flags to collect — picking one replaces the last,
which is what `/settings/mutes` renders.

Adding the third scope surfaced two holes in the **boost** source, both of them
the shape this module is built to prevent: `silenced_ids/3` read `account_mutes`
alone where its subquery twins read the union, so a member silenced through the
follow's own switch came back through a boost of their vutuv post; and the
author check asked only about `posts.user_id`, so a **page's** post was carried
in whatever the reader had muted (the nullable-pair trap of #1336, read from the
owner side). Both are closed, with a calibrated test each.

Two stores now hold a mute, so exactly one function answers whether an account
is silenced: `Mutes.scope_for/2` reads both, `mute/3` and `unmute/2` write both
(a `:all` mute of a followed account sets the follow's flag too, so the account
page, the following list and the feed band keep agreeing with the card menu).
The feed reads the sets as **subqueries** rather than through that function, so
a page costs no extra round trip — `muted_member_ids/2`,
`muted_organization_ids/2` and `remote_mute_rows/1`, the last of which the
fediverse follow-set lookup unions into the one query it already makes.

Where it acts: every source that can carry a stranger's post — a boost, a
member's reshare of a cached post or reply, the tag timeline, an answer under
the reader's own post. The live arrival is asked the same question in memory
(`Posts.reaches_feed?/3`, `via: :repost` for a reshare), or the "new posts" pill
counts a card the next load throws away. Deliberately **not**: a conversation the reader opens
themselves, their notifications, or the muted account's own page. A mute is
about what arrives unasked; going and looking is asking. Muting happens on a
card's ⋯ menu or an account page; `/settings/mutes` lists both stores together
and is where one is taken back.

Posts keep a **connections-only** audience that now resolves to "mutual
followers" (see [posts-and-feed.md](posts-and-feed.md)).

(The legacy `connections` request/accept table was retired; outstanding pending
requests were converted to follows, and the table is dropped in a follow-up
expand/contract deploy.)

## Following tags

Following a **tag** (issue #872, `Vutuv.Tags.TagFollow`, table `tag_follows`) is
the topic twin of following a person: a private subscription that pulls the
tag's posts into your `/feed`. It lives in `Vutuv.Tags`
(`follow_tag/2`, `unfollow_tag/2`, `tag_followed?/2`, `followed_tags/1`,
`followed_tag_ids/1`, `tag_follower_count/1`), not `Vutuv.Social` — a tag is a
`Vutuv.Tags.Tag`, not a person.

Unlike a person-follow it is **silent**: a tag has no owner, so following it
notifies no one and there is no public follower list — only the aggregate
`tag_follower_count/1` shown as social proof on the tag page. `follow_tag/2`
always sets `user_id` from the session user (never request params), is
idempotent (`ON CONFLICT` + a guard), and broadcasts `{:tag_follows_changed,
%{}}` on the follower's `Vutuv.Activity` topic so an open `/feed` redraws its
rails live.

What reacts to a followed tag: **the feed** gains a third source — posts
carrying a followed tag from authors you do *not* already follow (see
[posts-and-feed.md](posts-and-feed.md)). The feed rail's suggestion card used to
lead with members *endorsed* for those tags as well; that slot is the "New here"
welcome card now, so the people half of the feature lives only on the profile's
own "Who to follow" card.

Surfaces: the **tag page** header pill (`<.tag_follow_button>`, CSRF POST/DELETE
to `/tag_follows`), the feed's reload-free **"Tags you follow"** rail (a
`phx-click` ✕ per chip), and the **`/settings/followed_tags`** management list
(a settings-hub row that appears only once you follow at least one tag, like
saved searches).

### Where a followed tag reads from

A follow also carries its **sources** (issue #2125, `Vutuv.Tags.TagFollowSource`,
table `tag_follow_sources`): one row per source, `"vutuv"` — this installation,
written inside the follow's own transaction — plus any server the member picked.
`source` is either that literal or a bare lowercased hostname, and
`normalize_source/1` is the one place that turns a pasted URL or `@user@host`
address into one of the two. An address of **our own** becomes the local source
rather than a server to poll, `Vutuv.Fediverse.own_host?/1` deciding that, so no
installation ever asks itself for its own posts; a remote host is folded the same
way, `www.mastodon.social` storing as `mastodon.social`, because two spellings
would mean two rows and two fetches of the same posts.

**vutuv is always on and cannot be switched off** (#2128), from both sides:
`remove_tag_follow_source/2` refuses the local source, and a follow with no rows
at all reads as `["vutuv"]` — which is what the release before this one keeps
writing during the blue/green window, knowing nothing about the table.

What a member types here is fetched later by us, so the changeset carries the
same two-layer guard `Vutuv.Organizations.OrganizationDomain` uses: the
server-name grammar from `Vutuv.Fediverse.BlockedInstance`, plus
`Vutuv.Ssrf.internal_host?/1` — the grammar alone accepts `169.254.169.254` and
every private range. That check is literal-only (no DNS in a changeset), so the
fetcher still vets the host at fetch time. A tag merge that drops a duplicate
follow captures its sources first (`Merge.rescue_tag_follow_sources/3`, beside
the endorsement rescue), so a revert brings the follow back reading what it read.

A table and not a list on the follow, because the fetcher's question is the
other way round — which server-and-tag pairs does anybody here want? —
and `Vutuv.Tags.wanted_tag_sources_query/0` answers it with one grouped query
(`%{source:, tag_id:, tag_name:, follow_count:}`, the local source and every
merged alias left out), instead of unpacking every member's array. It is
composable on purpose: `wanted_tag_sources/0` orders it and runs it, and the
fetcher below builds its due filter on the same query rather than writing a
second copy of the join. The context side is `add_tag_follow_source/2`,
`remove_tag_follow_source/2` and `tag_follow_sources/1`.

### Reading those servers (issue #2126)

A hashtag has no inbox to subscribe to: ActivityPub delivers to addresses, not
to topics, and a remote server's own "follow a hashtag" only filters what it
already holds. So this is a **pull**. `Vutuv.Tags.ExternalTagClient` asks each
named server for its public tag timeline over the Mastodon-compatible REST API
all of them serve without an account, and keeps **text and a link to the
original**, never a picture. That is not thrift: every foreign image would go
through the AI image gate, and on a busy tag most posts carry one. The language
arrives declared, so even that costs no model call. Anything marked sensitive or
sitting behind a content warning is skipped outright, as are boosts, replies and
anything not public.

Two tables of their own (`external_tag_posts`, `external_tag_fetches`) and
deliberately **not** `fediverse_posts`: a row there is a cached ActivityPub
object and drags image ingestion, the AI gate, the screenshot queue and two
counting sweepers behind it, none of which a REST status read off a public
timeline is or should pay for.

**The pace is the tag's own business.** `Vutuv.Tags.ExternalPosts` aims at
roughly five new posts between two fetches: more arrived and the interval
halves, none arrived and it doubles, always inside ten minutes and three hours
(`EXTERNAL_TAG_CADENCE`). Measured, a tag that keeps answering empty walks
10 → 20 → 40 → 80 → 160 → 180 minutes, reaching the ceiling after eight hours of
quiet; one in the middle of a news event walks back down in the same five steps.
A budget per server is applied to the due list before anything is asked, so
twenty busy tags naming one popular server cannot spend its rate limit in a
single run.

**Every outcome moves the clock, skips included** — the #1316 lesson (see
`fediverse.md`). `checked_at` is the scheduler's clock, not a claim that the
question was asked: a pair that can never be fetched is stamped and rejoins the
queue at its own pace instead of holding the front of every batch for good. A
skip takes no strike and waits the ceiling, since an operator may unblock the
host tomorrow; a failure takes a strike and backs off by doubling.

**Three refusals, all of them at fetch time**, because the changeset above
cannot do DNS and cannot know what the operator will block next week: the
instance blocklist, which also drops a *status* whose author lives on a blocked
host; `Ssrf.vetted_address/1` with the connection **pinned** to the vetted IP
via `Http.get_pinned/4`, the hostname riding along in SNI, the certificate check
and the `Host` header, so no second lookup is left for DNS rebinding to answer
differently; and `Tag.hashtag_name/1`, which refuses a name that reduces to
nothing. That connection is opened and closed for the one request, which is
what bounds it: handing `Req` a per-host `connect_options` instead starts a
`Finch` instance per distinct hostname and never reaps it, and which hostnames
appear is decided by what members type into a follow's sources.

**A fourth refusal: our own posts** (issue #2179). A post written here goes out
with its hashtags in its `tag` array, so every server holding it indexes it
under them and serves it on its own public tag timeline — and asking that server
about a followed tag hands the post straight back. The author then read their
own words three times in their own feed: once as the post, then once per relay
under a "found through …" line carrying their handle and this installation's
host. `Vutuv.Tags.ExternalPost.written_here?/2` refuses it on the way in, asking
`Vutuv.Fediverse.own_host?/1` about **both** the author's host and the post's
address, since a relay that rewrote the author still hands back our permalink.
Measured on the live timelines that produced the report, 19 of the 23 ingestable
statuses on troet.cafe's `#vutuv` and 17 of 19 on mastodon.social's were this
installation's own. The rows already stored go with
`ExternalPosts.drop_written_here/0` on every fetcher tick — deleted rather than
blanked, because the gate means the delete cannot undo itself, and a standing
pass rather than a migration, because the release still serving traffic during a
blue/green switch files rows behind a migration that has already run.

What bounds the table is `EXTERNAL_TAG_POST_CAPS` (twenty posts per tag, its
servers sharing those slots, ten thousand rows overall) plus `prune/0`, which
takes a pair's schedule and its posts away with the last follow that wanted
them. Nothing here outlives somebody's interest in it, which is also the
retention answer for words their author never offered us.

### Showing what they found (issue #2127)

Those rows stand in the member's feed as ordinary cards
(`Vutuv.Tags.ExternalPosts.feed_items/4`, an eighth source beside the seven in
[posts-and-feed.md](posts-and-feed.md)) and fill the fediverse tab of a tag
page, which for most topics stood empty. A feed entry is the fourth row shape —
`%{id: "external-<uuid>", external_post: %ExternalPost{}, post: nil}` — spotted
by `Vutuv.Posts.external_feed_entry?/1` and drawn undecorated, since there is no
account row here to read like marks, pictures, quotes or a follow state from.

**The server we asked is not the author's home**, and that is the whole point of
the card. A tag timeline is a mixed bag: a post about Koblenz read off
troet.cafe was usually written somewhere else. So `external_tag_posts.author_host`
stores whose server it really is — the client computed it anyway, to ask the
blocklist about it — and `<.external_post_card>` heads the card with the
author's own `@name@host`, exactly as a cached post's card does, with the server
we read it from in a small grey line under it (`Found through …`). That line is
rendered even when the two coincide: it answers "how did this get here", and one
that vanished when the answers agreed would teach a reader that a card without
it came from the author directly, which is never true here.

**One post is one card, however many servers carried it** (issue #2163). A find
is stored once per (tag, server, remote id), so the same status read off three
servers stood three times in the feed and on the tag page, each card identical to
the one above it but for that grey line — and the figure over the list counted
rows, because rows is what there were: 78 showable rows for 49 originals on a
copy of production, and one tag page drawing 20 cards for 9 posts.
`Vutuv.Tags.ExternalPosts.fold_copies/1` groups them by `origin_key/1` and draws
one, preferring the `home_copy?/1` (the rare case — 8 of those 49 — so the
ordinary find is drawn from the copy stored first, which ids being
`Vutuv.UUIDv7` makes the first arrival). The other servers become the card's
provenance line instead: `Found through these servers` with the count, opening
to the list, the geometry a post's fediverse reactions already fold into. The
fold is asked of the **whole** scope a surface may show before that surface
pages it (`tag_finds/1` for a tag, the reader's own corpus for a feed), so the
count over the list counts posts and a group cut in half by a page's `LIMIT`
cannot come back on the next page under a different representative.

The row reaches **the member whose own follow named that server** — the query
joins their `tag_follows` and its `tag_follow_sources` — so somebody following
the same tag with vutuv alone sees none of it, and "found on three servers"
therefore means three of the servers that brought it *here*, never a claim about
the fediverse. Everything that governs an ordinary card governs these: hidden
words and muted tags
(`Vutuv.Posts.text/1` and `account_names/1` answer for this kind too), the
reader's own muted servers, their language filter, and a report that empties our
copy for everybody here at once.

That report **blanks the row rather than deleting it**. The pull re-reads the
same timeline every ten minutes to three hours with `on_conflict: :nothing`, so
a deleted row would be written straight back: a report that undoes itself before
the reader has looked away is not a control. The words and the author go, the
key stays as a tombstone, and `reported_at` keeps every reader off it. The
takedown is filed in the same content-free ledger a reported cached post is
(`Vutuv.Fediverse.log_reported_post/1`), so the operator's "one troll or this
whole server" question counts these alongside the rest.

**How far it reaches is two questions, not one** (issue #2164). One status read
off five servers under two tags is ten rows, and what relates them is
`Vutuv.Tags.ExternalPost.origin_key/1`: the post's own normalised address plus
the server its author lives on. That key only *describes* the copies — both
halves are written by whichever server we polled, and a member may name any host
as a tag source, so a card a hostile host invents can claim any address and any
author in one line of JSON. Who may act on the key is `home_copy?/1`: the row we
fetched **from the server the post and its author both live on**, the one claim
here that something outside itself backs, since we chose that host and asked it
ourselves. So reporting the author's own copy takes every copy of the original,
and reporting a relayed one takes the rows that same server filed — its own
words under the reader's other tags — and leaves everybody else's standing.
`Vutuv.Tags.ExternalPosts.reaches?/2` is that rule, and `reject_reported/1` asks
it again on the way in, so a tombstone can only refuse what its own report could
have blanked and a planted one cannot keep an honest post out of the table.
`report/2` answers `{:ok, :every_copy}` or `{:ok, :this_copy}` because the
member has to be told which of the two happened; the confirm dialog and the
flash are two sentences for that reason. What the authority half costs is that
most reports now take only the clicked row — every one of those was fetched
from a server other than the author's, and so is a row a stranger could equally
have invented; `reaches?/2`'s own doc carries the counts, measured over a
production copy, and says to re-measure rather than trust them, because this
table rolls over within hours. The first attempt at this keyed the takedown on
the description alone, shipped as `7cdfd4dc7` and was reverted as `8b2c1a862`
within the hour.

A **folded** card meets that rule head on, and the surfaces have to hold the
promise its dialog made. Reporting a card drawn from the author's own server
takes every copy, so the card leaves the page. Reporting one drawn from a relay
takes that server's rows and leaves the rest — so the card does not leave, it is
redrawn from a row the report did not reach and says one server fewer, which is
exactly what the reader was told before they pressed it. The feed does that per
card (`ExternalPosts.refold/1`, keeping the entry id so the card is patched in
place); the tag page re-reads the page, as it does for every other row-removing
act on it.

**The `www.` fold belongs to the description and to nothing else.** `www.<host>`
is a subdomain — a dangling CNAME or an old CDN target hands it to somebody who
does not hold the apex — so `origin_key/1` folds it (two spellings of one post)
and `home_copy?/1` does not (one server speaking for another's author). Folding
in both places let a member have this installation poll a mirror at the
author's alias and speak for them, and it cost nothing to close: the same rows
of a production copy are the author's own either way.
`Vutuv.Fediverse.strip_www/1` now
folds **every** leading label rather than one, because folding once could be
walked around by writing `www.www.<host>`, which
`Vutuv.Tags.TagFollowSource.normalize_source/1` would then store and poll as
`www.<host>`.

The **Mastodon API drops these rows** rather than rendering them
(`Vutuv.MastodonApi.Presenter.statuses/2`): every field of a `Status` that
matters hangs off an `Account` object, and inventing an id for an author we hold
no row for would put a dereferenceable-looking identity into every client's
cache. A client asking for its home timeline is talking to a server that can ask
those public timelines itself.

### Choosing those servers (issue #2128)

Every tag chip in the feed's "Tags you follow" card carries a small number: how
many servers feed that tag, **this installation included**, so a plain follow
reads `1` rather than `0`. Pressing it opens the panel that changes them, inside
the card (`tag_sources_panel/1` in `VutuvWeb.PostLive.Feed`) — the rail is
`hidden md:block`, so this is a desktop surface for now.

The panel offers the servers in **`TAG_SOURCE_SERVERS`**, ten by default, each
with its own description and size beside it: accounts, accounts active this
month and posts, read from that server's NodeInfo. That list is exactly what an
installation elsewhere has to change — an intranet reaches none of the ten and
names its own, or `TAG_SOURCE_SERVERS=""` and none at all. With
`FETCH_EXTERNAL_TAG_POSTS=false` the panel offers nothing and says so: a server
this installation may not fetch from is not one it can honestly offer.

**vutuv is always on**, and the panel says so rather than enforcing it: the rule
lives in the context, where `tag_follow_sources/1` answers with the local source
whatever the rows say and `remove_tag_follow_source/2` refuses to remove it. The
row is rendered with a `disabled` switch so a reader can see this installation
*is* a source and is the one they cannot take away.

**A follow may name three other servers** (`TAG_SOURCES_PER_FOLLOW`), enforced
in `Vutuv.Tags.add_tag_follow_source/2` rather than in the panel, because the
cost it bounds is the fetcher's: a pair is asked forever, up to 144 times a day
at the cadence floor. The parent's own measurement is what sets the number —
mastodon.social alone held 30 of the 30 newest posts over three tags and
troet.cafe 26, so two servers carry the fresh end and every further one returns
older material. Three is one more than the evidence needs.

**What a server has to pass** is one gate, `Vutuv.Tags.SourceServers.check/2`,
whether the member typed the address or pressed one of the offers: `https`
(refused rather than silently upgraded), a real server name that is neither an
internal address nor this installation, and then the server itself — the flag,
the operator's blocklist, the SSRF vet with the connection pinned, and the tag
timeline. Everything ahead of the probe is re-decided on every press, because
those are the parts that change without anybody asking; the literal half is
asked here rather than left to the changeset so a value that was never a
hostname costs a stranger's server no request at all.

`Vutuv.Tags.SourceServerProbe` does the asking and `tag_source_servers` stores
the answer for a day (`TAG_SERVER_INFO_MAX_AGE_HOURS`), so opening the panel a
second time costs nothing.

**The tag timeline alone decides `status`; NodeInfo only decorates.** A server
that serves its timeline but publishes no NodeInfo is pickable and simply shows
no figures — gating on NodeInfo would make the panel stricter than what the
fetcher needs, and strict on the wrong document. NodeInfo is then read for the
figures, *discovered* rather than guessed (`/.well-known/nodeinfo` names the
real document, whose path is the server's own business), and only its path is
followed, and only when the href is `https` and names that same host. **NodeInfo
carries no language** in either 2.0 or 2.1 — the badge comes from Mastodon's
`/api/v2/instance`, and a server that does not serve it keeps every other figure
and shows no badge.

`status` is `"ok"`, `"unreachable"`, or **`"account_required"`** — the server
answers and says the timeline is for members. Mastodon says that with **`422`**,
not the `401` the shape suggests; three of the eighteen servers measured while
shipping this do. `Vutuv.Tags.ExternalTagClient.refusal/1` is the one classifier
both readers of a public tag timeline use, so the fetcher reads 422 as "gone"
rather than taking a strike on every pass for a refusal that will never change.
Such a server is shown with its size and a line saying why, and cannot be
switched on; its OAuth path is a feature of its own.

The panel draws from what is stored and fills in behind itself (`start_async`),
because asking ten servers is dozens of requests and seconds of wall clock, and
a member who pressed a chip is owed the panel now. The markup is
`VutuvWeb.PostLive.TagSources`, a sibling of the feed's other pieces rather than
another 350 lines inside it — the tag page and an organization's Following list
both show followed tags with no way to say where they come from, and each is a
caller this panel is one refactor away from.

### Finding a tag that is suddenly busy (issue #2129)

Under the same card, below the tags this reader's own feed is already carrying,
sits a row of tags that are **spiking on the servers in `TAG_SOURCE_SERVERS`**.
Every Mastodon server publishes its trending tags with a seven-day history,
without a login and for one request each, so a member hears about a conference
or an alarm without having to already follow the tag it happens under. Pressing
one is the whole control: it mints the tag here if nothing answers to it yet,
follows it, and names the servers it is busy on as its sources, so the follow
brings something back instead of subscribing the reader to a topic nobody here
has written about. `Vutuv.Tags.Trending` decides what is offered,
`VutuvWeb.PostLive.TrendingTags` draws it, and the row rides in the feed's rail,
which is `hidden md:block`.

**Suddenly busy, not busy.** The history is the whole point: a tag is offered
when today's total across the servers listing it clears a floor, is several
times the median of the six days before it, and at least two servers list it at
all. Measured on 10 September 2026 against the shipped ten, `#warntag` stood at
5,994 uses against a median of 25 and `#xbox` at 130 against 78 — the second is
what `#xbox` does every day, and a rule that read volume alone would offer it
forever. Each pill wears those seven days as six quiet strokes and one accent
bar, so the reader can see the judgement rather than take it on trust; the same
figures are in the control's accessible name, grouped for the locale. The pill
is the same pill as the tags offered a few pixels above it, with the week sized
to fit inside it (issue #2180) — three rows of pills in one 309px card, and a
bottom row drawn to a recipe of its own read as a fault rather than as
emphasis.

**The row keeps its place when the offer is empty** (issue #2165). Judging on
today's volume means nothing anywhere can clear the bar for the first few hours
of a day, so the offer empties nightly; taking the label with it left a member
who saw five suggestions in the evening looking at a bare plus sign. The label
now stands and one muted line says what and why. What decides whether the row
exists at all is `Vutuv.Tags.Trending.asking?/0` — the flag plus a non-empty
`TAG_SOURCE_SERVERS` — because "nothing stood out today" is only honest where
somebody was asked, and an intranet installation reading no other server gets no
row rather than a nightly report about servers it never touches.

**The loudest tag is often a machine, and the spread does not catch it.**
`#mow4` trended on seven of the nine servers that answered — a bot farm that
federates widely trends everywhere. What catches it is one sample of the tag's
own timeline from its busiest server, where both facts are the remote server's
own: 40 of 40 statuses came from a single domain and 39 of them were flagged as
bot accounts, against 13 to 26 distinct domains and at most 10 of 40 bots for
every ordinary tag. A tag that cannot be sampled at all is **not** offered.

**A spike shortens the pull at once.** The cadence above is a measurement, so it
only learns about a news event after the event has already filled a fetch or
two. Every spiking candidate naming a tag followed here goes back to the cadence
floor on the spot (`Vutuv.Tags.ExternalPosts.hurry/1`) — before the vetting,
because hurrying a tag somebody already chose is a different question from
offering one to somebody who did not.

**One pass, every server, one clock.** `Vutuv.Tags.Trending.refresh/0` runs on
the fetcher's own two-minute tick and does nothing until a server is due
(`TAG_TRENDING_INTERVAL_MINUTES`), then asks **all** of them: the spread is a
count of servers, and a pass that asked three of ten would answer it from three.
`Vutuv.Tags.TrendCheck` is that clock and it is uniform on purpose — there is no
backoff, because a divergent one would bring a recovered server due on its own.
It is stamped on **every** outcome, skips included: the pass is due when any
server is, so a
server that can never answer would otherwise make the whole pass run on every
tick instead of every half hour, which is issue #1316's deadlock in this
feature's shape. The offer itself (`tag_trends`) is replaced wholesale by each
pass and read back as at most eight stored rows, so drawing the row costs one
small select and never a request.

## The tag page (`/tags/:slug`)

A tag's public page is the topic page: its description, the most endorsed
members, the open positions carrying it, and below them the **timeline** —
everything written about the topic, from both worlds, in one list.

The timeline is `Vutuv.Tags.Timeline`, a SQL union of three sources:

- **vutuv posts** carrying the tag (`Vutuv.Posts.tag_posts_query/1`, which is
  itself the union of the composer's tag field and the body's `#hashtags` — see
  [posts-and-feed.md](posts-and-feed.md)), in the anonymous public view;
- **posts cached from other networks** whose hashtags name the tag
  (`Vutuv.Fediverse.RemotePostTag`, filled at ingestion by
  `Vutuv.Fediverse.Hashtags`), **public audience only**. `unlisted` is not a
  smaller kind of public — it means the author asked their own server to keep
  the post off its discovery surfaces, and a topic page crawlers read is exactly
  such a surface — and a followers-only post is not ours to publish at all;
- **posts read off other servers' public tag timelines** (`external_tag_posts`,
  issue #2127), which is what fills this tab for a topic nobody here follows an
  account about — and that is most topics. No audience to re-check: only public
  statuses are ever stored. They carry no like tally of their own (we hold text
  and a link, not an object with a `likes` collection), so sorting by likes puts
  them at the bottom beside the cached posts whose origin serves none.

The first two ingestion paths **mint** a tag the site does not have yet: writing
`#Eisenach` declares a topic as plainly as typing it into the composer's tag
field, and resolving hashtags against existing tags only meant the catalog grew
from that field alone. Three bounds keep it from becoming an open write. A body
may mint at most `Vutuv.Tags.max_minted_hashtags_per_body/0` (five) tags against
`max_hashtags_per_body/0` (twenty) filings. `Vutuv.Tags.mintable_hashtag?/1`
refuses a name whose slug would not name it — `#2026` and a CJK hashtag both
produce a URL that says nothing about the page. And the fediverse side never
sees a stranger: `Vutuv.Fediverse.record_remote_post/2` stores a post only from
an account somebody here already follows, so what arrives is what our own
members chose to read. A minted page also stays `noindex` and out of the sitemap
until a **local** member or a **local** public post carries it, so a remote post
can leave a tag page behind but never a crawled one.

The reader's controls are the embedded `VutuvWeb.TagLive.Timeline` LiveView
(`live_render` from `VutuvWeb.TagController.show/2`, the profile's and the post
permalink's pattern, so the controller keeps owning the URL and the agent-format
siblings): the All / vutuv / Fediverse **source tabs** (`<.post_filter_tabs>`,
which the tag timeline still uses — the feed traded its own for a filter band,
see [posts-and-feed.md](posts-and-feed.md)), a **sort** (newest, oldest, most
liked), a full-text
**search** over both sides' `search_tsv`, a **date range** read as German
calendar days, and "Load more" — none of them reloading the page.

Sorting by likes is lopsided and the page says so where it applies: a member's
post has a real tally (its hearts plus the favourites that arrived over
ActivityPub), while for a cached remote post there is no public number vutuv may
show, so it counts as zero and lands last. Being off-router the LiveView cannot
`push_patch`, so the controls do not rewrite the address bar — but the
controller passes `?source=`, `?sort=`, `?q=`, `?from=` and `?until=` into the
mount session, so a shared link opens on exactly that view, and the agent
formats honour the same params.

## One topic, one tag: alternative names and merges (issue #1338)

A topic used to spread over several tags that share no letters — `Ruby on
Rails`, `rails`, `ROR`, `rubyonrails` — each with its own page, its own members
and its own half of the timeline. A tag can now carry **alternative names**, and
an alternative name is **a tag row pointing at its topic**
(`tags.merged_into_id` + `tags.alias_kind`, one of `alias` / `abbreviation` /
`former`), not a row in a separate names table.

That shape buys three things at once:

- the absorbed **slug keeps resolving**, because the row that owns it is still
  there — `VutuvWeb.TagController`'s `resolve_tag` plug answers `/tags/<alias>`
  with a **301** to the topic, carrying the query string, and the endpoint's
  `AgentFormat` plug re-appends the extension so `.md` lands on `.md`;
- the absorbed **id survives**, so a merge is exactly revertible;
- an alternative name **cannot collide** with a real tag, since both live under
  the same unique index on `slug`.

`Tag.find_by_value/1` follows the pointer, so typing any spelling attaches the
topic instead of minting a duplicate — that is what stops the sprawl regrowing.

One name at a time is not enough, though: every tag field on the site takes a
**batch** ("PHP, ROR, Ruby on Rails"), and once two of those names resolve to
one topic the batch is naming it twice — which the member cannot see, the
spellings looking nothing alike. So a batch goes through
**`Vutuv.Tags.canonical_tag_names/1`** first: it resolves the whole list in one
query, exactly the way `find_by_value/1` resolves one name, and drops the
duplicates that resolution creates, keeping the first spelling typed. Without
it the second spelling comes back as a failed duplicate on a form that had just
promised both. Four callers owe it — the add-tag form's live preview and its
save (`VutuvWeb.TagNewLive`), sign-up (`Accounts.register_user/3` **and**
`User.registration_changeset/2`, so the three-tag minimum counts topics rather
than spellings and an account can never land holding fewer tags than the form
demanded), and the post composer (`Vutuv.Posts`, where the count is also the
five-tag cap). It deliberately does not judge a name: a value `add_user_tag/2`
refuses — a web address, punctuation — passes through untouched, so each caller
keeps its own refusal and its own error message for it. Job postings resolve
per name and dedupe on the resulting tag ids instead
(`Vutuv.Jobs.resolve_tag_ids/1`), which lands in the same place.

The price is one rule every tag query owes: **an alternative name is never a
topic of its own** (`Tag.not_merged/1`). Forgetting it puts a second page for one
topic back in front of a reader, silently, so
`test/vutuv/tags/merged_tags_hidden_test.exs` walks the surfaces one at a time —
directory, search, the indexability bar and sitemap, hashtag links, the add-tag
preview, honor tags, the newsletter audience builder. The admin catalog
(`/admin/tags`) is the deliberate exception: it lists them, marked, linked to
their topic.

**Merging** is `Vutuv.Tags.Merge`, driven from `/admin/tag_merges`
(`VutuvWeb.Admin.TagMergeLive`; its own path segment because the earlier
`resources("/tags", …)` in the router would read `merge` as a slug). The screen
collects a **set** of spellings across several searches and absorbs them into
one chosen survivor, each as its own recorded merge (`merge_all/3`), with
`preview_many/2` counting what the sequence really does rather than summing the
pairs — merging `A` and `B` into `C` for a member holding `A` and `B` moves one
row and drops the other. A single merge moves
every row filed under the absorbed tag — profile tags and the endorsements under
them, post tags and body hashtags, tag follows, job postings, cached remote
posts, newsletter audiences — and only deletes a row whose owner already holds
the surviving tag, because of the `(owner, tag)` unique index. A member carrying
both spellings ends up carrying the topic once, and their endorsers' vouches move
onto the row that survives.

Every merge is written to `tag_merges` with an `undo` payload — the ids it moved
and the **whole content** of the rows it had to drop — and `revert/1` puts all of
it back, re-inserting dropped rows verbatim through `jsonb_populate_record` so
they keep their ids and anything pointing at them still does. The row-moving is
SQL rather than Ecto for exactly that reason: a revert restores a *row*, not a
schema's idea of one.

Four refusals are rules rather than judgement calls: an **honor tag** never
merges (it is granted, not spelled), an **alternative name** never merges again,
a pair recorded in `tag_distinctions` as **different topics** stays refused
whichever way round it is named, and a pair whose names differ **only in
characters the slugifier deletes** is refused outright — that is the `c` / `c++`
/ `c#` / `µc` bucket from issue #1337, four languages one normalization would
fold into one. A separator is not such a character: `open source` and
`OpenSource` are the ordinary mechanical variant a merge is *for*.

Typos are deliberately out of scope. There is no `misspelling` kind: a typo is
unbounded, a near-miss pair is exactly where a wrong merge does the most damage,
and catching one buys almost nothing.

### The assisted pass (`Vutuv.Tags.Assistant`)

An admin-triggered batch that **proposes** merges and never applies one. Three
deterministic rules over the tag *names* generate the candidates, and only then
does a local model judge them:

| rule | finds | measured on the real catalog |
|---|---|---|
| `same_key` | the names agree once case and separators are folded away (`javascript` / `java script`) | 318 pairs |
| `acronym` | a multi-word name's initials are another tag's whole name (`ROR` / `Ruby on Rails`) | 496 pairs |
| `token` | a short name is one whole word of a longer one (`rails` / `Ruby on Rails`) | 4,182 pairs |

Those figures are why the code is shaped the way it is, and they came from
running the generators against a copy of production rather than from reading
them. `token` is four fifths of everything found and almost none of it is a
merge: `Linux` shares a word with `embedded linux`, `arch linux`, `linux kernel`
and twenty more, all of which are specializations, not spellings. So two things
follow. A `token` pair is written **only** when the model has vouched for it —
unjudged it is a chore, not a proposal. And the queue is ranked by **rule
first**, size second: ordering by members affected alone (what the issue asked
for) puts every one of those `Linux` rows above the obvious `javascript` /
`java script`, because the biggest tag is exactly the one every specialization
shares a word with.

There is deliberately **no edit distance and no trigram similarity**, although
`pg_trgm` is installed: both are typo catchers, and typos are out of scope.

The cap (500 by default) is what one pass may **add**; pairs already waiting do
not spend it, so scanning again reaches further down the list instead of
re-offering the same top rows. What was dropped is reported and logged, never
silently trimmed.

The refusals from the merge apply to the proposal too, so the queue can never
offer something that would be refused on approval — but they are applied in
bulk, one query and a string comparison, **not** by calling `Merge.preview/2`
per pair: the preview counts rows in seven tables and the catalog generates
about 5,000 pairs. The preview belongs on the review screen, asked once about
the pair an admin is actually looking at.

The model (`:tag_merge_assist`, `Vutuv.Ollama`, structured output) is asked one
narrow question per pair and told to answer "different topics" whenever unsure,
because the two errors do not cost the same: a missed duplicate stays a
duplicate, a wrong merge moves other people's rows. It is the guard for cases no
rule can settle — the catalog offers `seo` / `search engine optimization` (a
merge) beside `seo` / `search experience optimization` (not one). With the flag
off or Ollama unreachable, the queue fills unjudged and a human decides.
Approving a proposal does not merge it: it loads the pair into the pickers
above, where the preview shows what would move.

## Blocking

Reachable wherever you decide to block someone — a quiet "Block" next to the
profile footer's Report, a calm overflow menu in the direct-message thread (the
moment unwanted contact usually arrives), and a "Block someone by @handle" form
on `/blocks` itself (so the "block my ex" case needs no detour through their
profile).

All three run the same `Social.block_user/2`. Blocking severs both follow edges
(`Social.sever_between/2`, which also ends any vernetzt status), freezes the 1:1
conversation, and refuses every new interaction in **both** directions (follow,
message, reply, like, repost); third-party reposts of a blocked author also stay
out of the blocker's feed.

Reading is untouched (public stays public).

The blocked party only ever sees the same generic refusals a decline/freeze
produces.

The private list at `/blocks` also unblocks; unblocking restores nothing
(deliberately unlike a rejected moderation report) but thaws the conversation
its own block froze, unless a reverse block or an active report severance still
stands

## Content filters (muted words & tags)

Topic-level muting, the third layer above per-follow mute and the block
(issue #940): `Vutuv.ContentFilters` is a member's private, viewer-only deny
list, managed at `/settings/filters` ("Muted words & tags") and in the feed's
filter band. Each `content_filters` row mutes a **tag** or a **keyword/phrase**
(with `*` wildcards); keyword rows match the post body **and** its tags/hashtags,
tag rows match the post's tags only.

A row also carries an **`account`** scope: `*` (the default, and what every row
written before the column existed says) reads every account, anything else
narrows the rule to the accounts whose handle or display name it matches, with
the same `*` wildcard. It exists because a news house publishes the same story
under a dozen accounts in a dozen spellings, so the phrase worth silencing is
worth silencing *there* rather than across the whole timeline:
`*@social.heise.de` reaches `@heiseonline@social.heise.de` and
`@ct_Magazin@social.heise.de` alike. The names a post is matched against come
from `Vutuv.Posts.account_names/1`, the one function that answers "who is this
from" for all three post kinds; a post whose account cannot be named never
matches a scoped rule.

Unlike a muted follow (which drops a *person* out of the feed via the query),
content filters run **after** the feed page is hydrated: the feed compiles the
viewer's whole list once (`compile_for/1`) and asks `filtered/2` per post
which filter, if any, hides it. A match does not vanish — the post collapses to a
"Show anyway" line (`PostLive.Feed`, `data-filtered-post`), so a filtered post
never silently shortens the feed or breaks a reply thread; the reveal is
in-place and survives the midnight restream. The viewer's **own** posts are never
filtered.

Keyword matching is a compiled, case-insensitive regex (`compile_pattern/2`):
`*` → "any run of characters", literal segments escaped, word-boundaries by
default (so `cess` does not hide "success") except on a side opened with `*`.
The list is owner-only — never public, never in the agent formats — capped
(`ContentFilters.max_filters/0`), and rides along in the GDPR export. `expires_at`
is a column reserved for a later "snooze" UI (not honored yet).
