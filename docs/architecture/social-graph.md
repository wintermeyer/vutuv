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

Two things react to a followed tag:

- **The feed** gains a third source — posts carrying a followed tag from authors
  you do *not* already follow (see [posts-and-feed.md](posts-and-feed.md)).
- **The "Who to follow" rail** leads with members endorsed for the tags you
  follow (`Vutuv.Tags.people_for_followed_tags/2`), the people half of the
  feature.

Surfaces: the **tag page** header pill (`<.tag_follow_button>`, CSRF POST/DELETE
to `/tag_follows`), the feed's reload-free **"Tags you follow"** rail (a
`phx-click` ✕ per chip), and the **`/settings/followed_tags`** management list
(a settings-hub row that appears only once you follow at least one tag, like
saved searches).

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
list, managed at `/settings/filters` ("Muted words & tags"). Each
`content_filters` row mutes a **tag** or a **keyword/phrase** (with `*`
wildcards); keyword rows match the post body **and** its tags/hashtags, tag rows
match the post's tags only.

Unlike a muted follow (which drops a *person* out of the feed via the query),
content filters run **after** the feed page is hydrated: the feed compiles the
viewer's whole list once (`compile_for/1`) and asks `filtered_pattern/2` per post
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
