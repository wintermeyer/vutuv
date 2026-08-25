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
query builders, so the gates cannot drift). On a profile mount they do not
even run alone: `Social.profile_count_queries/1` hands the three arms to
`UserProfileLive.profile_counts/2`, which unions them with the nine section
totals and the viewer-scoped posts total
(`Posts.author_timeline_count_query/2`) into ONE counts query per mount.
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

## The tag page (`/tags/:slug`)

A tag's public page is the topic page: its description, the most endorsed
members, the open positions carrying it, and below them the **timeline** —
everything written about the topic, from both worlds, in one list.

The timeline is `Vutuv.Tags.Timeline`, a SQL union of two sources:

- **vutuv posts** carrying the tag (`Vutuv.Posts.tag_posts_query/1`, which is
  itself the union of the composer's tag field and the body's `#hashtags` — see
  [posts-and-feed.md](posts-and-feed.md)), in the anonymous public view;
- **posts cached from other networks** whose hashtags name the tag
  (`Vutuv.Fediverse.RemotePostTag`, filled at ingestion by
  `Vutuv.Fediverse.Hashtags`), **public audience only**. `unlisted` is not a
  smaller kind of public — it means the author asked their own server to keep
  the post off its discovery surfaces, and a topic page crawlers read is exactly
  such a surface — and a followers-only post is not ours to publish at all.

Both ingestion paths **mint** a tag the site does not have yet: writing
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
siblings): the All / vutuv / Fediverse **source tabs** (the feed's
`<.post_filter_tabs>`), a **sort** (newest, oldest, most liked), a full-text
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
