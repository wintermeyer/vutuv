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

**Mute** is a per-follow flag (`follows.muted`, `<.mute_button>` → PUT
`/follows/:id/mute`): a muted follow keeps the relationship and any vernetzt
status but drops the followee's posts out of *your* feed — silent and
one-directional, unlike a block.

Posts keep a **connections-only** audience that now resolves to "mutual
followers" (see [posts-and-feed.md](posts-and-feed.md)).

(The legacy `connections` request/accept table was retired; outstanding pending
requests were converted to follows, and the table is dropped in a follow-up
expand/contract deploy.)

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
