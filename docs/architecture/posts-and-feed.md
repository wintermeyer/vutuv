# Posts and the newsfeed

Markdown posts, deny-based audiences, the `/feed` timeline, likes / bookmarks
/ reposts, reply threads and post images. Business logic lives in
`Vutuv.Posts` (saving *people* is `Vutuv.Social`).

## Posts and the feed

Markdown posts (up to 20k chars) with images and tags.

An **`@handle` of an existing member is auto-linked** to their profile with the
member's name as a hover tooltip, and a **`#hashtag` is auto-linked** to that
tag's `/tags/:slug` page **only when that page has something to show** — the tag
exists here and carries either at least one visible member or at least one
visible post (`Vutuv.Tags.linkable_slugs/1`), so a link never lands on an empty
tag page. This runs everywhere the Markdown renderer does (`VutuvWeb.Markdown`:
posts, chat messages, ads, the RSS/JSON renderings), skipping entities typed
inside code spans/blocks or existing links and resolving all of a body's
mentions and hashtags in one batched query each.

A hashtag also **files the post under that tag**, so the link points both ways:
`Vutuv.Posts.PostHashtag` (table `post_hashtags`, re-derived from the body on
every save, existing tags only — a typo never leaves a tag page behind). It is a
separate table from `post_tags` on purpose: `post_tags` is what the card renders
as tag chips, and a hashtag is already visible in the sentence it was written
in, so filing it there would print it twice.
`Vutuv.Posts.visible_tagged_posts_query/0` unions the two, which is what every
"which posts carry this tag" reader asks — the tag timeline, the indexability
bar, the `tag:` search operator and the hashtag-link gate above.

The composer's tag **field** takes at most `Vutuv.Posts.max_tags_per_post/0`
(five) tags, and past that the save fails with an error on `:tags` instead of
quietly keeping the first five (issue #1237) — a member must not lose something
they typed to a post that publishes anyway. The count is taken after the dedupe,
so repeating a tag never trips it, and the composer's pill box refuses the sixth
pill client-side (`<.tag_input max={…}>`) so it rarely gets that far. Everything
else the parser drops is still dropped silently — punctuation, a bare link, a
repeat — because none of those can become a tag at all. Filing by hashtag is
uncapped: a body may name as many tags as it mentions.

A **bare `http(s)://` URL is auto-linked too**, with its display text shortened
to host + first path directory — but only *outside* code. Inside a fenced block
or an inline code span a URL is sample text, so it is left verbatim
(`VutuvWeb.Markdown.map_outside_code/2`); rewriting it turned `curl
https://vutuv.de` into visible Markdown link syntax.

### Who a post is by (issue #1334)

A post is authored by a **member or an organization**, never both and never
neither:

| column | personal post | organization post |
|---|---|---|
| `user_id` | the member, `delete_all` | NULL |
| `organization_id` | NULL | the page, `delete_all` |
| `acting_user_id` | NULL | who pressed publish, `nilify_all` |

Three columns rather than one because two promises collide. `posts.user_id` was
`null: false, on_delete: :delete_all` — deleting your account deletes your posts
— but a post published for a page must survive the person who wrote it leaving.
Keeping the human in `user_id` would delete the page's content with their
account; dropping the human entirely would leave nobody accountable for what was
said in the page's name.

**`Vutuv.Posts.author/1` is the single accessor.** The author is read in ~70
places; reading `post.user` directly is a bug on an organization post, and so is
hand-building `~p"/#{post.user}/posts/#{post.id}"` instead of calling
`Posts.path/1`. Both mistakes shipped and broke live pages — see the trap
section in `organizations.md`.

Consequences worth knowing:

- Organization posts carry **no audience** (the deny model is built on the
  author's own follower graph and blocks), so a denial has nobody to name.
- They **can be answered**, by a member here and from another network (#1336).
  What used to refuse it was that a reply reaches nobody; the page's activity
  list is the recipient that made it defensible, so `post_replies` carries
  `parent_organization_id` beside `parent_author_id` and `broadcast_reply/2`
  notifies no member for such a parent. Answering itself stays a member's act —
  `create_reply/3` takes a `%User{}`.
- They have their own feed source (`feed_organization_post_items/3`), so
  `feed_post_items/3` stays deliberately the member half.
- Personal scopes exclude them: a member's profile, archive and feed never show
  what they published for a page. That association is what `acting_user_id`
  keeps internal.

### The author's own, proven webpage (issue #1246)

A link in a post that points at a webpage the **post's author** has proved is
theirs (`Vutuv.Profiles.LinkVerification`, see `profiles.md`) wears the same
small emerald ✓ the profile's Links card shows. Without it a reader has no way
to tell the author's own site from any other address in the text.

What the mark may claim is `Vutuv.Profiles.VerifiedLinks`' decision, and it is
deliberately never wider than the proof:

| proof | covers |
| --- | --- |
| `dns`, `well_known` | the whole host — any link on it |
| `rel_me` at the host root (`/` or no path) | the whole host |
| `rel_me` on a deeper path | **that one URL** and nothing else |

The last row is the shared-hosting case: a member who proves
`example.com/~alice` with a rel=me back-link has said nothing about
`example.com/~bob`, who is a different person, nor about
`example.com/~alice/foo`. Comparison parses with `URI.parse/1` (never a string
prefix), treats `www.` and the apex as one party, `http` and `https` as one
site, and ignores a trailing slash, the query and the fragment — a reader who
pastes a link carrying `?utm_source=` is naming the same page. The path keeps
its case; a case-sensitive server really does serve two pages.

Only the **post author's** verified links are ever consulted: verification
carries no uniqueness constraint (two members may each prove the same shared
host), so a global lookup would hand a stranger's proof to the wrong person.
They ride in on the already-preloaded author (`Vutuv.Posts.post_preloads/0`
scopes the `urls` preload to `verified_at is not null`), so a feed of fifty
cards costs one batched query rather than one per card; a surface that renders
a card without that preload marks nothing rather than firing queries.

`VutuvWeb.Markdown.mark_verified_author_links/2` writes the mark, on the
rendered HTML like the code highlighter and for the same reason. It goes
*inside* the anchor, after the label — part of the link a reader taps, and out
of reach of the entity linker, which skips everything inside an `a`. The
author's own anchor text is never replaced by the profile entry's description:
those are the author's words in their own sentence. The mark is icon-only, so
the whole statement is its escaped `title` / `aria-label`, naming exactly what
was proved ("Verified webpage of the author (example.com/~alice)"); the look is
`.verified-author-link` in `assets/css/components.css`.

The mark does not travel alone: its `<svg>` is an atomic inline, and UAX #14
lets a line break in front of one, so a link ending flush with the line put the
tick on the next line by itself in Chrome and Firefox (Safari never broke there
— reported on #1307). The renderer therefore wraps the label's trailing word plus the
mark in `.verified-author-glue`, a `white-space: nowrap` box. Only a **short**
slice joins it (`@glue_chars`, 12): `nowrap` also suspends `.markdown`'s
`overflow-wrap`, so gluing a whole address in one box would scroll a phone's
post column sideways. A label with no plain-text tail (it ends in a tag or an
entity) keeps the bare mark rather than risk a slice through markup.

Local posts only. Remote/fediverse content renders through `render_remote/1`
and its author is not a member with verified links, and the outgoing
ActivityPub Note, the RSS item and `VutuvWeb.PostJSON` stay unmarked as well —
an emerald tick is this site's vocabulary, not something to push onto another
server's renderer. The permalink's agent siblings carry the fact as **data**
instead: `verified_author_links` on the post doc (`address`, `url`,
`verified_method`, `scope`), plus one sentence in the md/txt renderings.

An installation with `:verify_user_links` off simply has no verified links, so
nothing marks — it falls out, no extra gate.

### Fenced code blocks

A fence that names its language (` ```elixir `) gets that language printed in
the corner of the block, and its comments, strings, numbers and keywords in
colour. Both happen **on the server**, in `VutuvWeb.CodeHighlight`, which runs
at the end of the `VutuvWeb.Markdown` pipeline (posts, messages, ads, feeds) and
in `VutuvWeb.DevDocMarkdown` (the `/developers` docs, legal pages). The page
ships **no** highlighting JavaScript and no new dependency: the readers who
never see a code block download nothing extra, and the browser side is the
`.codeblock` / `.hl-*` rules in `assets/css/components.css`.

It works on the rendered HTML rather than the Markdown because the sanitizer
strips attributes off `<pre>` and `<span>` — so the step runs after the scrubber
and builds its own markup from parts it controls. Nothing user-written reaches
an attribute: the label and the `language-*` class come from
`VutuvWeb.CodeHighlight.Languages` for a known language and from a
`[a-z0-9+#._-]` slice of the fence word otherwise. The code text arrives escaped,
so highlighting decodes it, tokenizes and re-escapes each token; a block whose
escaping cannot be rebuilt byte for byte, or one over 20KB, keeps its label and
skips the colouring rather than risk mangling someone's snippet.

`VutuvWeb.CodeHighlight.Lexer` is a scanner, not a parser — comments, strings,
numbers and known words, in two flavours (general code, markup). Adding a
language is a keyword list in `Languages`, not a grammar. An unknown language
still gets its label; `text`/`plain`/`none` and a fence with no info string are
left exactly as they were.

A ```` ```diff ```` fence is the one language whose **body** is not tokenized
here: it gets the label and nothing else (`family: :none`), because
`VutuvWeb.CodeHighlight.Diff` runs right after and turns it into real added /
removed rows (issue #1108, below). That is why the order in `render_pipeline/2`
is `CodeHighlight.render/1` first — the diff renderer then still finds a plain
`<pre><code class="language-diff">` sitting inside the labelled wrapper.

### What else a fence may say

The info string may carry two more facts, each written either after a colon or
as an attribute (issues #1137 and #1138):

    ```php:config/app.php          ```php title="config/app.php"
    ```diff:php                    ```diff lang="php"

A **title** names the file the snippet comes from and renders as a real header
bar above the code — a real element, not a CSS label, because a file name is
part of what the snippet says and the same HTML travels to RSS, mail and the
fediverse, where our stylesheet does not. A **`lang`** on a `diff` fence names
the language the diff is written in, so the rows get both the added/removed
tint and the token colours; without it a diff is the one block that stays grey
however well we know its language.

`VutuvWeb.CodeHighlight.Fences` owns that grammar, and the short form is the
one that gets stored, because two links in the chain understand a single word
and nothing more:

* **Earmark** does not ignore the rest of an info string, it stops seeing a
  fence at all — the whole block collapses into one run of inline code. So
  ` ```js react ` had always rendered as garbage, not just the new syntaxes.
  `Fences.normalize/1` folds the info string into one canonical word
  (`language[:sub][!percent-encoded-title]`) before Earmark sees the line, and
  `Fences.parse/1` reads all three facts back off the `class` afterwards.
* **Milkdown** keeps a code block's first word as its `language` attribute and
  serializes only that, so an attribute-form title would be destroyed the
  moment a post is re-opened in the composer. `rewriteFenceInfo` in
  `assets/js/markdown_editor.js` folds it into the colon form on the way in,
  the same shape of guard the footnote transforms are.

`/system/markdown` documents all of this for members, and renders its own
examples through the same code (`VutuvWeb.HelpController`), so the page cannot
describe a feature the renderer has stopped supporting.

### The composer previews the fence

The Milkdown composer shows the plain source inside a code block — the `+`/`-`
markers are what a member edits — but it no longer shows a plain grey box for
the whole block: that read as "the fence did not work" and got issues #1108,
#1137 and #1138 reopened ("when something looks broken in the preview, I'm
hesitant to submit"). `codeFencePreview` in `assets/js/markdown_editor.js` is a
ProseMirror decoration plugin that mirrors what the renderer will do: added and
removed diff rows get the published tints (their markers coloured like the
gutter), hunk and file headers are quieted, and the block carries the corner
language chip or the file-name bar (`.mde-codeblock*` / `.mde-diff--*` in
`components.css`, light and dark).

The row classification mirrors `VutuvWeb.CodeHighlight.Diff.classify/1`, and
the display names come from the server — `VutuvWeb.UI.markdown_editor/1` writes
`VutuvWeb.CodeHighlight.Languages.editor_labels/0` onto the editor root as
`data-mde-langs` ("php:PHP|…", the emoji-group-labels arrangement) — so no
second registry lives in JavaScript; the "no language" words carry an empty
label, the sign to leave such a block alone. Token colouring stays server-side
on both surfaces: the preview is decorations over the stored source, not a
shipped highlighter. Drift guards live in `markdown_code_fence_test.exs` and
`components/markdown_editor_test.exs`.

### Footnotes

A body may annotate itself (issue #1147):

    Ein Satz mit Anmerkung[^1].

    [^1]: Die Anmerkung dazu.

The reference renders as a superscript `[1]` linked to a numbered note list at
the end of the body. The jump is **one-way**: a note carries no back-link. One
shipped for an afternoon and was read as stray line-break characters — it is the
only mark in the list that is not content, the convention comes from books and
wikis where the reader has scrolled far, and clicking a citation pushes a history
entry, so the browser's own Back already returns the reader to their exact spot.
`VutuvWeb.Markdown.Footnotes` owns it, and it works the way the inline-image and
`diff` steps do, for the same reason: the syntax becomes unguessable plain-text
markers *before* Earmark, and the real markup is built from known-safe parts
*after* the scrubber, which allows `id` on no tag and `class` only on `<code>`.
Earmark's own `footnotes: true` is therefore no use here — its links would
survive with every one of their targets stripped, and its ids (`fn:1`) are
global, so twenty feed cards would all claim the same anchor. Ours carry a
per-render nonce.

The rules are strict on purpose. A definition is a **single line from column 0**;
notes are numbered by **first reference**, not by definition order; a label cited
twice shares one note; code is sample text; and at most 50 notes per body.
**Half-typed syntax stays exactly as typed** — a reference with no definition and
a definition nobody cites both render literally, so nothing a member wrote ever
disappears without a trace.

`render_preview/3` takes the definitions out *before* the ~1000-character cut and
puts back the ones the surviving text still cites: they live at the end of a
body, so cutting them off would strand every reference above as literal source.
The brackets in `[1]` are load-bearing, not decoration — Mastodon and most feed
readers drop `<sup>`, and without them the number would fuse into the word it
follows.

The composer has **no footnote node**: `[^1]` stays ordinary text in the WYSIWYG,
which is what a member typing it expects to see. Two remark behaviours have to be
papered over in the hook, both silent — it escapes `[` in prose, and it parses
`[^1]: https://example.com` (the most natural footnote there is) as a CommonMark
link reference definition, a node the commonmark preset cannot render, so
re-opening such a post would drop the line. `escapeFootnotes` on the way in and
`canonicalizeFootnotes` on the way out fix both; the backslash is never visible
and never stored. `VutuvWeb.Markdown.Footnotes` also reads through the escape, as
the guard for bodies stored before that existed.

Everything post-related lives under `/:slug/posts`: the author archive
(`/:slug/posts`, scopable to a year/month/day — `/:slug/posts/2026/06`), and
permalinks keyed by the post's UUID v7: `/:slug/posts/:id` (non-canonical casing
redirects to the lowercase URL).

The feed at `/feed` is a member's **home once they follow at least one account**
(`Vutuv.Social.follows_anyone?/1`): logging in then lands here, and the vutuv
logo / visiting `/` redirect here (`VutuvWeb.Home`).

A member who follows nobody yet (most visibly a brand-new sign-up, whose feed
would be empty) lands on their own **profile** instead, where they can fill it
in and find people to follow.

It is a LiveView: a collapsed compose tile (the same dashed `<.empty_add>` tile
as the profile's Beiträge section) expands the inline composer, a pull-model
timeline (own + followed authors' posts **and reposts**, with a "Reposted by X"
line) with cursor "Load more", a *"Show N new posts"* pill fed by `{:new_post,
…}` / `{:new_repost, …}` broadcasts, and a desktop-only **"New here"** welcome
rail: five of the newest members who show a face
(`Vutuv.Social.newest_members_with_avatar/1`, a pool of 30 ordered by the UUID
v7 primary key), drawn at random, each with their job title and three of their
tags picked at random so a ↻ shows another side of the same person. It replaced a most-followed
suggestion rail: a ranking shows the same well-connected members to everybody
and can never reach the person who signed up this morning, who is the one for
whom being seen decides whether they come back. Following somebody here
**keeps** their row, flipped to "Following" — the greeted member vanishing on
the click read as if it had undone something — and only a fresh draw retires
them.

`Posts.feed_page/2` merges **six** sources through `Vutuv.FeedPage` (a shared
cursor over independent fetchers). Three are local: own + followed authors'
posts, their reposts, and — since issue #872 — posts carrying a **tag you follow**
(`feed_tag_items/3`), from authors you do *not* already follow (so following a
tag widens the feed with new voices without duplicating the follow path; muted
and blocked authors stay out exactly as elsewhere). Following a tag lives in
`Vutuv.Tags` — see [social-graph.md](social-graph.md). The feed also carries the
reload-free **"Tags you follow"** rail (chips + a `phx-click` ✕ unfollow). The
other three come from `Vutuv.Fediverse` — cached posts of accounts you follow
out there (#1161), what people you follow *here* reshared from another network
(#1166), and what those accounts boosted (#1167) — see
[fediverse.md](fediverse.md).

**What keeps that first source cheap.** The local posts source ("mine plus the
people I follow", newest first) has to stay a *page*-sized read as the posts
table grows, and two things make it one. `posts_recency_index` covers its sort
key `(inserted_at DESC, id DESC)` — without it Postgres reads every post ever
written and top-N sorts, because the `my own OR my followees'` disjunction rules
out the per-author indexes. And the query names its author join `as: :author`,
which makes `scope_visible/2` spell the moderation gate as
`Moderation.Query.account_hidden_row/1` (reading the joined row) instead of the
correlated `account_hidden/1`, whose de-correlated form scans all of `users` per
post query. Any post query may opt in the same way: naming the binding is the
only signal, and it changes how the question is asked, never the answer. For the
queries that legitimately cannot join the author, `users_hidden_index` (partial,
on the four columns that hide an account) keeps the EXISTS off a full scan.
Measured on a copy of production seeded to 200,000 posts, the two indexes took
that source from 76.7 ms to 0.53 ms.

**Source tabs: All / vutuv / Fediverse.** Above the timeline sits the same
segmented control the profile's post-type tabs use
(`PostComponents.post_filter_tabs/1`, here with `feed_filter_options/0` and the
`filter-source` event). The split is `feed_page/2`'s `filter:` option, which
picks the sources rather than filtering their rows: **vutuv** runs the three
local sources plus the boosts of a *local* post, **Fediverse** the cached posts,
the local reshares of one and the boosts of a *remote* post. The rule is what
kind of post an entry carries (`Posts.remote_feed_entry?/1`, the same question
the renderer asks to pick a card), so every entry lands on exactly one tab and
the two together are "All" — a member's post that an account out there boosted
is a vutuv post, however it arrived. The one source producing both kinds
(`Fediverse.feed_remote_boosts/4`, issue #1167) is narrowed by `only:` **inside
its query**, not by dropping rows afterwards, so a narrowed page is as full as
an unnarrowed one and `more?` stays honest.

Switching a tab reloads the timeline from the top (`stream reset: true`) — the
tab decides what the query pulls, so it cannot be applied to what is already on
screen — and drops the pending batch with it, since the fresh page already
carries whatever waited behind the pill. Live arrivals are gated by the
in-memory twin `Posts.feed_filter_accepts?/2`: a followed member's post neither
appears nor counts toward the pill while the Fediverse tab is open. The one
exception is the **viewer's own** post, which must be visible after they press
Post — there the feed switches back to "All" rather than swallowing it. The
choice has no URL behind it (this LiveView is off-router and cannot patch), and
the agent-format siblings (`/feed.md|txt|json|xml`) always serve the whole feed,
exactly as the archive's siblings ignore `?type=`.

**The tab outlives the visit** (issue #1499). A click stores it on the member —
`Posts.remember_feed_filter/2`, a narrow `update_all` on `users.feed_source`
(NULL = All) — and `Posts.remembered_feed_filter/1` reads it back at mount off
the struct the session already loaded, so the opening filter costs no query and
the **dead render** already draws the right tab with the right entries. Four
things it must get right, each of which the tests cover:

* The **gate runs first**. A remembered "Fediverse" whose content has since gone
  away shows no tab bar, and opening behind it would strand the reader on a
  timeline with no way out — so the mount folds the filter back to `:all` while
  leaving the stored value alone, and the tab returns with the content.
* The write happens in the **event handler**, not in `load_source_filter/2`: the
  same helper runs when the member's own post lands on a tab that cannot hold
  it, and that fallback is the code's doing, not a choice to remember.
* It goes through `update_all` rather than a changeset, because a socket's
  `%User{}` was loaded at mount and can be hours old — writing the whole struct
  back would undo whatever changed meanwhile, from another device or another
  tab. Nothing asks first whether the value differs; that question cannot be
  answered from a possibly-stale struct, and the write is one row by primary key.
* The **`MountHandoff` subject carries the filter** (`{:feed, filter}`). The
  stash holds one entry per member, not per socket, so with a bare `:feed` a
  second device — or the same device after the tab changed between its HTML and
  its socket connecting — would take a page computed for another tab. Keyed by
  the filter a mismatch is simply a miss, and that mount loads its own page.

It is deliberately **not** broadcast to the member's other devices. A live tab
switch there would reload a timeline somebody is reading from the top, taking
its pending batch, its loaded pages and its scroll position with it — and
reading vutuv on the desktop while the phone sits on Fediverse is a reasonable
thing to want. The next visit is soon enough.

**The bar is shown only to a member the fediverse actually reaches** (issue
#1267). For anyone else "Fediverse" can never fill, so "vutuv" is the same
list as "All" and the three tabs are one timeline under three names — which is
what the reporter saw. The gate is `Posts.fediverse_feed_available?/1`, and it
asks **the Fediverse tab's own sources** (one row each, `Enum.any?/2`
short-circuiting) rather than any member-level flag, for two reasons. The
obvious flags are wrong: `Fediverse.federated?/1` is about *publishing
outward* — their opt-in, their actor, their standing — and "do they follow a
remote account" misses the member with no fediverse involvement whatsoever who
still has remote posts in their feed because somebody they follow *here*
reshared one (`feed_remote_reposts/3`, issue #1166). And asking the sources
cannot drift from what the tab renders, which a hand-maintained condition
would. Every remote source short-circuits to `[]` while `:fediverse_enabled`
is off, so the installation switch needs no separate check. The answer is read
once per mount and rides the handoff — it is a fact about the whole timeline,
not the open tab — so a member who follows their first remote account while
the feed is open sees the bar on their next load. An empty *tab* keeps the bar
(reachable once the content leaves under the reader — muting the account it
came from), or they would be stranded on a tab they cannot leave.

**A tab you are not on says something landed there** (issue #1503) — a coral
dot beside its label (`post_filter_tabs/1`'s `unseen`), cleared by going there
(`load_source_filter/2` → `clear_unseen/2`; "All" clears both, a named tab only
itself). Only the two named tabs ever dot (`unseen_tabs/1`): "All" holds the
same posts, so a dot there was true and read as a third place with news of its
own. A dot and no count: what the reader needs is that there is something
over there, and the tab reloads from the top anyway. The socket's
`:unseen_sources` is never stored — it means "since you have been looking at
this page", so a fresh mount starting clean is the honest state.

The two halves reach it differently, and the difference is what each write
knows about the reader:

* **A vutuv post is already broadcast.** `insert_entry/3` used to drop an
  arrival the open tab cannot hold; now it dots that tab's source instead. The
  tab check moved **below** `Posts.visible_to?/2` for it: while the answer was
  "do nothing" the order was free, and it is not free for a dot — lighting a
  tab for a post the reader is turned away from is exactly the lie to avoid.
  A regression test is calibrated against the old order.
* **A fediverse arrival broadcast nothing at all**, so the four writes that put
  a row on that side now send a bare nudge to the local followers of the account
  or the resharer: `record_remote_post/2`, `record_remote_boost/2` (both to the
  followers of the sending account — the boost path reads its row back first,
  because `ON CONFLICT DO NOTHING` cannot say whether *this* delivery wrote it
  and an `Announce` arrives once per follower), `repost_remote_post/2` and
  `repost_note/2` (the resharer plus their unmuted followers here). The nudge
  carries the stamp the entry will wear in the merged feed and nothing else:
  whether the row reaches this particular reader depends on their mute, the
  follow's state, the audience and their language filter, so the feed asks its
  own sources (`Posts.newest_source_entry/3`, one `LIMIT 1` per source, the
  shape `fediverse_feed_available?/1` uses). It hands the entry back rather
  than a boolean, because the ticker below quotes it. Only the tab the reader
  is **not** on is probed — "All" holds both halves, so nothing ever landed
  elsewhere — and a member with no tab bar pays no query.

**And for a few seconds it says what landed** (issue #1668). The dot is the
standing mark; beside it the bar quotes the arrival — author and first words —
and then goes. `post_filter_tabs/1` takes a `ticker` map for it and the tab it
names shares its warm tint for the length of the window, which is the whole
mechanism for "which tab is this about" with a tab in between. On a narrow bar
the other tabs fold their labels to zero width and the quote takes the room
(a container query on `.filter-tabs`, so the settings page's example box
behaves like a phone on a desktop screen); measured on a 356 px bar, that is
the difference between no room for a quote at all and about twenty characters.

Five rules keep it from becoming a nuisance, and each one has a test:

* **One quote per window.** A second arrival inside it cannot replace the
  first (both would stand for less time than it takes to read one) and cannot
  queue behind it (ten would hold the bar open for a minute and a half), so
  the quote gives up and becomes a count. The clock is **not** restarted by
  it, or a busy source would own the bar: `data-ticker-window` stays put while
  the count climbs, and that attribute is what the browser's timer keys on.
* **The browser owns the clock** (the `FeedTicker` hook). A window counted out
  on the server would include the trip back, and a hide that never arrives —
  a dead socket — would leave the quote standing forever. The hook hides it
  and then reports `hide-tab-ticker`, which only clears the server's copy so a
  later patch cannot put it back.
* **A silence after each window** (`:feed_ticker_cooldown_ms`, 2 s), longer
  than the 400 ms fold-back. Arrivals are not evenly spaced on a bad line — a
  reconnect delivers a backlog at once — and without it the bar would close
  and reopen in the same breath. What lands inside the silence still gets its
  dot.
* **A muted word is never quoted.** `decorate/3` stamps `:filtered_by` only on
  the branch for the tab the reader *is* on, so the teaser asks
  `filtered_pattern/3` itself and falls back to the bare dot. The bar is the
  one place a member cannot scroll past it.
* **Not into a browser left over from the previous release.** A deploy does
  not reload an open feed: the socket reconnects to the new release and
  patches into a document downloaded hours ago. Everything else the feed
  streams is markup whose CSS that browser already has — the ticker is new
  markup with a stylesheet and a hook of its own, so on the v7.347.0 deploy
  the quote drew as an unstyled 200-character paragraph across the tab bar
  that no clock ever took away. `mount_feed/2` reads `static_changed?/1` once
  (connect params exist only during mount, and it answers only because
  `root.html.heex` marks both assets `phx-track-static`); a stale client keeps
  the dot and skips the quote until the next full page load.

Only ever one tab at a time: `other_source/1` is nil on "All" and the two named
tabs partition the feed, so a third source would be the first thing to need a
rule for two open windows. Two member preferences (`Vutuv.Prefs`, group
`:feed_tabs`): `feed_tab_ticker?` (on) and `feed_tab_ticker_seconds` (8, from a
fixed list of 4–20 on /settings/preferences, where an example plays the
combination currently selected).

**The discovery rail renders with the page.** The rail (Tags you follow / Who
to follow / Suggested posts) was lazily loaded for one release (v7.200.3: an
empty aside plus a `LazyRails` hook asking for it after connect), and the
pop-in after the paint read as the page being *slow* — so the laziness was
deliberately undone (v7.200.8). The rail is computed once in `feed_payload/1`
on the dead render and rides the mount handoff to the connected socket (see
[realtime.md](realtime.md)), so a visit still pays its queries only once.
Phones keep it hidden under `md` by CSS and pay those queries on the dead
render — the accepted cost of the immediate desktop paint. The periodic
reshuffle timer is armed at connect; the refresh paths
(`:refresh_suggestions`, `{:tag_follows_changed, _}`) redraw unconditionally.

**Both suggestion cards read a snapshot, and neither trusts it.** "Who to
follow" takes its pool from `Vutuv.Social.PopularUsers`, "Vorschläge" from
`Vutuv.Posts.PopularPosts`: one GenServer each, re-ranking every ten minutes
into a `read_concurrency` ETS table, with `:miss` falling back to the live
query so boot and tests behave exactly as before. The reason is the same for
both, and it is not the page load — it is that timer above. Every open feed tab
redraws the rail every five minutes, so the old per-viewer ranking scaled with
tabs left open rather than with people reading, while the expensive half of the
question ("which posts in this language were well received, one per author,
best first") has the same answer for every reader on the installation.

What stays per request is the half that is actually personal, and for
`discover_posts/2` that is where the old three-tier ladder went: the tiers were
always one ordering over one candidate set (a stranger's post ahead of a
followed author's, whose post must also be from this fortnight), so they are a
`CASE` in the draw's `ORDER BY` now instead of three ranking scans, and the
draw shuffles *inside* each tier — shuffling across the whole set silently
throws the preference away. The ladder itself is still the code that runs on a
`:miss`.

The rule the design rests on: **the pool proposes, the database disposes.** A
snapshot is minutes old and moderation is not, so the draw re-applies the full
anonymous visibility gate plus the viewer's blocks and mutes to the candidates
it picked. That check is affordable exactly because it is bounded to a few
hundred known ids. Staleness can therefore cost a reader a slightly out-of-date
*suggestion*, never a post they were not allowed to see — `popular_posts_test.exs`
holds one case per way the world can move after a snapshot (post frozen, author
frozen / suspended / deactivated / unreachable, post restricted, author blocked
or muted since).

The composer's body field is the shared **Milkdown WYSIWYG Markdown editor**
(`VutuvWeb.UI.markdown_editor/1` + the `MarkdownEditor` hook, also used by the
message composer). It edits Markdown *source* in place — the field stays a
`<textarea>` and the body is still stored and rendered as Markdown — so nothing
downstream (`VutuvWeb.Markdown`, the `.md`/`.txt`/`.json`/`.xml` siblings)
changes. See `.claude/rules/design.md` for the component and its gotchas — above
all that the editor takes the server's value at mount and then only when
`seed=` changes (`reset_composer/1` bumps it after a post and after *Discard
draft*). The body echoed back by `validate` is the writer's own text returning,
and re-parsing it would throw their caret to the end.
**Cmd/Ctrl+Enter submits** (issue #1196, `submit_on="cmd-enter"` — the same
opt-in the message composer passes, one handler in the hook); the shortcut
respects a disabled submit button, so it cannot post past the photo-upload
guard, and the "?" shortcuts overlay lists it.

**Emoji** (issue #1197) are picked from the 🙂 toolbar button's picker or typed as
a shortcode (`:tada:` becomes 🎉 on the closing colon, aliases included). What a
body stores is the emoji **character**, never the shortcode, so this is a
client-side feature end to end: `assets/js/emoji_data.js` holds the table,
`emoji_picker.js` the panel, and no server code takes part — a character is
already correct in the HTML page, every agent-format sibling, RSS, mail and the
fediverse. Both surfaces work in the message composer too.

**A post appears at most once.** When several followed members repost the same
post — or the viewer already follows its author, so it would also show as its
own original — the entries collapse onto the newest event
(`Posts.collapse_reposts/1`), and the surviving card shows an overlapping
**avatar stack** of the reposters the viewer follows (plus the viewer),
newest first, capped at five faces with a `+N` chip and an "and N others" tail
(`Posts.attach_reposters/2` fills the roster in one query; the banner is
`PostComponents.reposted_banner/1`). Cross-page the LiveView drops a repost of a
post already on screen, and a live `{:new_repost}` for a shown post grows that
card's stack **in place** (no reshuffle — it only climbs to the repost's
position on the next reload).

**Preview truncation.** A timeline card (`mode={:preview}`) clamps the body with
the `.post-clamp` CSS class and, when there is more, shows a plain "Read more"
control (no length metric — issue #880 dropped the word count as meaningless once
the reader has the preview). The line budget is a **per-reader, per-breakpoint
preference** (`Vutuv.Accounts.User.post_prefs/1`, set on the language & display
settings page): desktop and mobile independently, shipped default 6 lines on
desktop / 8 on a phone. Since the `Vutuv.Prefs` system (see
`settings-and-account.md`) the resolution is member value → the admin-set
**installation default** (`/admin/preferences`) → that shipped default; a nil
column means "inherit", and a logged-out reader gets the installation defaults
too. The reader's values ride onto the post body as the
`--post-clamp-desktop` / `--post-clamp-mobile` custom properties
(`VutuvWeb.PostComponents.post_body_style/1`, which stays `nil` only while the
resolved prefs equal the **shipped** defaults — the values the CSS fallbacks
mirror — so a default reader's DOM carries no inline style; under a changed
installation default every reader gets the inline override, which is what
makes the admin's choice take effect); `.post-clamp`'s `@media (width < 48rem)`
rule swaps the mobile value in. An explicit `0` count means **no truncation**
on that breakpoint (`-webkit-line-clamp: none`); when the reader disabled
truncation on
**both** breakpoints the card renders the whole body uncut like `:full` (no
character cap, no clamp, no "Read more"). Hyphenation of the post body is the same
kind of per-reader, per-breakpoint preference (`--post-hyphens-*`; the CSS
fallbacks reproduce the historical default of off on desktop, on for the narrow
phone column).

The **whole body is always shipped** to the DOM (no server-side cut) — a preview
renders the same Markdown as `mode={:full}`, **including the post's inline
images**, and the CSS clamp does the visual cut: `.post-clamp` (line clamp) for
a plain text body, or the height-based `.post-clamp--media` once the body
carries inline images (a line clamp can hold neither pictures nor floats; the
media cap is the reader's text budget plus a 24rem picture allowance, so the
authored image is visible on the feed instead of sitting below the cut). So "Read more" is a **single in-place toggle `<button data-post-expand>`**,
identical on the feed and the profile and for a post of any length: clicking it
drops the clamp and reveals the rest of the text with a short height animation
(`togglePreviewExpand` in `app.js` measures the clamped and full heights around
the class flip and transitions between them, honoring `prefers-reduced-motion`),
and flips its own label to **"Show less"** (`data-label-more` / `data-label-less`)
so the reader can fold it back — no navigation, no reload. A long post expands in
place just like a short one; nothing links out to the permalink. (The feed's
discover-rail teaser is separate — it still cuts its body via
`VutuvWeb.Markdown.render_preview/2` because a rail row links straight to the
post.)

Visibility and position of the control are driven **entirely by the wrapper's
`is-clamped` / `is-expanded` state classes + the `.post-preview__more` component
CSS** — the control carries **no** `hidden` / `inline-block` display utilities, so
the "two competing `display` utilities, the later-emitted one silently wins"
cascade trap that caused the false "Read more" on every post (issue #880) cannot
recur. Because the body is only ever CSS-clamped (never cut), the server can't
know whether it overflows — wrapping is width/font-dependent — so `is-clamped` is
set purely on the client: the `PostPreviewClamp` JS hook (a `[data-post-preview]`
sweep on classic pages, re-run on resize and `document.fonts.ready`) sets
`is-clamped` when the clamped node hides content — the standard test, body
`scrollHeight` exceeds `clientHeight` (+1 for rounding) — and it skips an
already-`is-expanded` preview so a later resize/font sweep can't re-clamp it out
from under the reader. With JS off such a card keeps the native line-clamp ellipsis
and no control. The permalink (`mode={:full}`) never clamps.

The profile page and the archive show the author's timeline (posts + reposts).

## Automatic post deletion (issue #1255)

A member can let their own posts age out: `Vutuv.Posts.AutoDeletion`, configured
on `/settings/auto_post_deletion`. **Off for everybody until they switch it on**,
and deliberately not a `Vutuv.Prefs` knob, because prefs fall back to an
installation default and no admin may set a default that deletes somebody
else's posts. All of it lives on `users`, prefixed `auto_post_deletion_*`.

The rule is one query, `due_query/1`, and both callers go through it: the
settings page's confirmation counts with `count_due/1`, the nightly pass deletes
with `run_for/2`. That is load-bearing rather than tidy — the dialog tells the
member an exact number and then deletes, so a second, separately written query
would eventually make that number a lie.

What it takes: the member's own posts older than `auto_post_deletion_after_days`
(a fixed list of ages from `User.auto_post_deletion_day_options/0`, one day up
to two years; a select, not a free number field, because a typed "1" where "10"
was meant is not recoverable). What it keeps:

| Kept | Why |
| --- | --- |
| the pinned post, a frozen post, one with an open moderation case | never optional: the first is the member's own showcase, the other two are evidence in somebody else's complaint |
| `…_keep_photos?` (default on) | photo posts and book/film reviews took work, and their files go with them |
| `…_keep_answered?` (default on) | deleting a post that started a conversation does not delete the replies, it guts the thread they live in. Counts **any** answer, local or from another network |
| `…_keep_bookmarked?` (default on) | the per-post escape hatch: bookmark your own post and the rule steps over it. No new UI, the glyph is already on every card |
| `…_delete_replies?` (default **off**) | the one switch that defaults to deleting *less* by being off: your reply sits inside a conversation that is not only yours |
| `…_min_likes` / `…_min_bookmarks` / `…_min_reposts` (0 = off) | a post that reached the floor is kept. Likes and reposts count what other networks did too (the figure `shown_counts/1` shows on the post); bookmarks are local, since a bookmark is private to whoever made it |

Deletion runs through `Vutuv.Posts.delete_post/1`, so photo files, open clients'
action bars, the moderation case and the fediverse `Delete(Tombstone)` are all
handled exactly as on a manual delete. **"Asks" is the honest word** for that
last one, and the settings page says so in as many words: a remote server that
is offline, that has defederated or that ignores the activity keeps its copy,
and copies people made by hand are out of reach entirely.

Saving is two steps whenever the new rule would delete something *now* — on
first switch-on and equally on a later tightening, which is the moment a member
is least likely to have worked out the consequence. Step 1 applies the
submitted rule to an in-memory copy, counts, and re-renders the page with a
confirmation naming the figure (and a link to the data export). Step 2 saves and
runs the member's own pass **uncapped**: they were shown an exact number and
pressed the button for it.

`Vutuv.Posts.AutoDeletionSweeper` runs the nightly pass at Berlin 00:30, one
pass per member per Berlin day, capped at `per_pass_limit/0` posts per member so
a ten-year backlog spreads over a few nights instead of firing thousands of
federation deliveries in a burst. `auto_post_deletion_swept_on` is stamped on
**every** pass, including the ones that delete nothing: it is the scheduler's
clock, not a claim that work happened, and a member the sweeper can do nothing
for must not hold the front of the oldest-first batch (the `CountsRefresher`
deadlock of #1316 is exactly that shape). Each pass that deleted something
writes one `posts_auto_deleted` line into the member's account activity log
(`docs/architecture/account-activity.md`), so a day's deletions are one entry
with a count and never a stream; a settings change writes
`auto_post_deletion_changed` beside it.

## The pinned post (issue #1110)

A member can pin **one** of their own posts to the top of their profile, so
the thing they are proud of stays visible however much they write afterwards.
"One" is structural, not a rule the code enforces: it is the nullable
`users.pinned_post_id` column (`ON DELETE SET NULL`, so deleting the post
simply unpins it), the same shape the profile job pin uses. `Vutuv.Posts`
owns it — `pin_to_profile/2` (author-scoped, replaces any earlier pin),
`unpin_from_profile/1`, `pinned_post/2` (visibility-scoped and preloaded, no
query when nothing is pinned) and the `pinned?/2` predicate the UI reads.

The affordance is the post card's author ⋯ menu, everywhere a post renders:
"Pin to profile" (`PUT /posts/:id/pin`) or "Unpin from profile" (`DELETE`),
both CSRF links like Edit and Delete. Pinning while another post holds the
spot asks first ("Only one post can be pinned to your profile…"), so the rule
shows up where it bites instead of in a help text, and both actions land on
the profile with a flash, where the change is visible.

On the profile the pinned post renders in its **own brand-tinted block above
the timeline** (`#pinned-post`), carrying the card's brand "Pinned post"
banner (`<.post_card pinned?>`, `data-pinned-banner`) — and the timeline below
leaves it out, so it shows once and nobody wonders why an old post leads the
card. The block belongs to the unfiltered "All" tab only: the Own posts /
Reposts / Replies tabs are the plain timeline, where the post takes its
chronological place again. The archive (`/:slug/posts`) is unaffected — it is
history, not a showcase. The agent formats mirror the page: `ProfileDoc` puts
the pinned entry first with `pinned: true` (md/txt append "(pinned post)")
and drops it from the timeline list, and a pin that is restricted, frozen or
invisible to the viewer is simply absent, in every format.

Other networks see the pin too: for a federating member it is published as the
ActivityPub **`featured` collection** and pushed to their followers as
`Add`/`Remove`, so Mastodon and friends show the same post at the top of the
profile they render — same anonymous-public gate, see
`docs/architecture/fediverse.md`.

## The composer keeps what you typed (issue #1148)

A page reload used to empty the composer, with no warning and no way back.
LiveView's form recovery does not help here: it replays a form's `phx-change`
on a socket **reconnect**, while a reload throws the page away and builds a new
one from the server. So the composer stores what it is holding and reads it
back when it opens.

**Where it is kept.** `post_drafts` (`Vutuv.Posts.PostDraft`), one row per
member per *composer context* — three partial unique indexes enforce that:
at most one new-post draft, at most one per post being answered, at most one
per remote reply being answered. The row mirrors the composer's own fields
rather than a post: `body` and `tags` are the raw strings in the form, `photos`
the per-photo alt/caption/switch panel, and `image_ids` names the still-pending
`post_images` rows in the author's order (the first photo leads the mosaic, so
the order **is** the layout, which is why it is an array and not a join table).
The `review` column (the retired book/film panel's values) is unused since the
review form went and gets dropped in a later deploy, like `mode`.

**When it is written.** From every handler that changes the content, debounced
through `send_update_after/3` to the component itself — so no host LiveView
needs a handler for it, and a burst of keystrokes costs one write rather than
one per character. `:composer_draft_debounce_ms` sets the pause (5s shipped —
it was 1.5s, which re-rendered the whole composer about once per sentence while
somebody was still writing it; `0` in the test env, where it writes inside the
`validate` that changed something so a test never races a timer). It is an **autosave**, so it never
interrupts: an invalid changeset simply skips that round, and a draft holding
nothing is deleted rather than stored, so clearing the composer clears it.

**What happens on restore.** The composer refills, and says so — a brand-tinted
"Picked up where you left off." line above the form with a *Discard draft*
action, which resets to the composer's opening state (on the reply page that
still includes the `?quote=` passage). The notice steps aside on the first
edit. `/feed` opens its collapsed composer when a draft exists (resolved in
`Feed.mount`, so the disconnected render agrees and the panel never flickers),
because text hidden behind a collapsed panel reads exactly like text that was
thrown away. Nothing restored is trusted: `Posts.pending_images/2` re-checks
every image id against the author's own unattached rows, and the post changeset
validates the content on save as it always did.

**Where it stops.** The **edit page** has no draft. Its composer opens full of a
*published* post, and quietly restoring a weeks-old unsaved edit over text other
people have already read is a different and much less welcome promise.

**Lifecycle.** A successful save drops the draft (in `handle_save_result/2`, so
all four branches are covered). `Vutuv.Posts.DraftSweeper` removes drafts
untouched for `Posts.draft_max_age_days/0` (30) — a draft is a convenience, not
an archive. `sweep_pending_images/1` spares any photo a live draft still names,
so a restored draft never comes back with holes in it; those photos go when
their draft does. The row cascades with the account and with the post being
answered, so `Accounts.delete_user/1` needs no new step, and drafts ride in the
GDPR export (`Vutuv.Export`, schema v6) — content the member never chose to
publish is theirs to take with them.

**The dialog that used to be here is gone.** The first attempt at this issue
armed `beforeunload`, so a reload with a draft in the composer raised the
browser's "Leave site?" prompt. It worked, but the wording is the browser's own
and cannot be set — every browser has ignored a custom `beforeunload` string
since ~2016 — so it could never say what was actually at stake. With the
content kept there is nothing left to warn about, and the prompt went with it.

## Editing closes (the edit window)

An edit rewrites what other people already put their name to: like "I love
kittens", and after the author's edit your like sits under "I hate kittens" —
without anyone telling you (issue #1023). So a post is only editable while it is
young and untouched, and `Vutuv.Posts.update_post/2` is the chokepoint that
enforces it (web composer and API alike):

- `{:error, :edit_window_closed}` once the post is older than
  `Posts.edit_window_minutes/0` — 30 minutes by default, configurable per
  installation (`:post_edit_window_minutes`, env `POST_EDIT_WINDOW_MINUTES`).
  The window exists for the typo you spot right after posting.
- `{:error, :edit_engaged}` once **anyone has liked, reposted or answered** the
  post, even inside those minutes: each of the three leaves a person standing
  behind text they no longer chose.
- A **frozen** post (a moderation case in the owner's court) is the one
  exception: "Fix it" is one of the three ways out of the freezer, and nobody
  but the owner can see the post meanwhile, so age and reach are ignored.

Deleting is never blocked. `Posts.editable?/1` is the full check (one query);
`Posts.edit_window_open?/1` is its no-query half, which is what the post card's
⋯ menu gates the "Edit" item on so a feed page costs no extra round trip per
card. A post liked inside the window therefore still shows the menu item, and
`VutuvWeb.PostLive.Edit` redirects to the post explaining which half is shut.
The API answers both cases `409` (`reason: edit_window_closed` /
`edit_engaged`).

This subsumes the old audience lock (below): a reposted or answered post cannot
be edited at all any more, so the lock only still fires inside a moderation
round, where the freezer exception reopens editing on such a post.

Audiences are **deny-based** (`Vutuv.Posts`): a post with no denials is public;
denials exclude groups of the author's followees, single users, or wildcards
(`non_connections`, `non_followers`, `non_followees`, `logged_out`, `everyone`).
New posts publish **public** — the composer no longer offers an audience picker.
The deny model still stands behind it: an already-restricted post keeps its
audience when edited, and a custom one still shows the "Hide from…" sheet (a
person typeahead) so its per-user denials stay editable.

The search page (`/search`) also finds words in **fully public** posts (Postgres
FTS over a generated `search_tsv` column, `websearch_to_tsquery`, 'simple'
config); any denial keeps a post out of search.

Any denial also hides the post from logged-out visitors and noindexes it; a
followers-only post shows a follow teaser and a connections-only (mutual-follow)
post a follow-each-other teaser to denied readers, every other denial 404s.

Deleting a group that posts deny is refused (it would silently widen audiences).

## Likes, bookmarks, reposts

Every post card carries an action bar with three renderings of one rule
(`VutuvWeb.PostLive.ActionBar`): on LiveView host pages (feed, /likes,
/bookmarks, reply, profile) it is the in-process
`VutuvWeb.PostLive.ActionsComponent` (no per-card process or subscription;
other people's counts refresh on reload); on dead controller pages (author
archive, profile served dead) each card embeds the standalone
`VutuvWeb.PostLive.Actions` LiveView via `live_render`, which subscribes
itself and ticks live; and on the **post permalink** the thread host
(`VutuvWeb.PostLive.Thread`) subscribes to its shown posts and forwards
`{:post_counters, …}` into the in-process bars via `send_update`, so the
post's own page ticks live with one process per visitor.

Counters are counted live from the `post_likes` / `post_bookmarks` /
`post_reposts` rows and broadcast as absolute values on the post topic
(`"post:<id>"`).

**Nobody likes their own post, and "own" is a narrower word than it looks.**
The self-vote rule (issue #1030) asks `Posts.self_vote?/2`, which is about
**identity**: a member and their post, a page and its post. It is deliberately
not `Posts.author?/2`, which asks whether somebody may act *in the author's
name* and therefore answers yes for every publisher of a page. The two are the
same question for a member and part company on a page, and while the rule
borrowed `author?/2` every publisher was barred from the heart on their own
page's posts — their like, not the page's, and named under the post since
#1233 — while a colleague without the role could press it. The action bar
renders the heart either way and swallows the refusal, so the symptom was a
control that did nothing rather than an error anyone could report.

### Who liked it (issue #1233)

The **post permalink** — and only the permalink — names the members behind the
like count: a row of linked faces under the post reading "Liked by NAME and N
others" (`Posts.post_likers/2`, one query for that one post, fed to
`<.post_card likers=…>` by `VutuvWeb.PostLive.Thread` and refreshed from the
same `{:post_counters, …}` tick that moves the number). A feed card keeps the
plain count: a per-card avatar row down a long timeline is a query-batching
problem and visual noise, and there is deliberately no likes subpage.

Being named is a member preference, `like_attribution?` (`Vutuv.Prefs`, group
`:privacy`, shipped default **on**, member switch on `/settings/privacy`,
installation default at `/admin/preferences`). Three rules hold it together:

- **The count never moves.** The row's `+N` chip is the difference between the
  total the button shows (`shown_counts/1`, so a favourite from another network
  counts like any other like) and the faces beside it, so a member who opted
  out rides in the `+N` — a figure that was public anyway. One member's private
  choice must not shrink another member's tally.
- **The post's author is the exception** (`include_hidden?: true`): they were
  told the member's name in the like notification at the time, so hiding it
  afterwards would be a promise we could not keep. The row says so to them
  ("Only you see everyone here…") rather than letting them read it as public.
- **The agent formats are anonymous-only.** `PostDoc` lists attributed members
  alone on every path, including the authenticated `/api/2.0` reads, because a
  doc's reader is never that author.

Hidden accounts (frozen, deactivated, suspended, unreachable) and unconfirmed
ones drop out of the row like they do from every other public people list;
their likes still count.

The engagement a bar starts from is **batched by its host, never queried per
card**: the feed decorates each page's entries via `Posts.post_engagement_map/2`
(one query for the page including nested thread parents), and the profile does
the same for its Beiträge preview, the nested parents *and* the pinned post
(`UserProfileLive.attach_engagement/3` → `:posts` entries +
`:pinned_engagement`). A bar only self-loads when nothing was handed in (a lone
card on a dead page). `user_profile_perf_test.exs` and the feed's batching test
fail the build if a host drifts back to one query per card.

Likes and bookmarks work on any visible post **and on any member** — from a
profile a logged-in visitor can like / bookmark another member (`Vutuv.Social`,
tables `user_likes` / `user_bookmarks`), a private, silent save that needs no
follow or connection and is refused only across a block.

The private saved-items hub at `/likes` and `/bookmarks` lists both saved
**posts and saved people**, each under a **Posts / People** sub-tab, with a
search box (post body + author name; person name, `@handle`, headline) and a
sort control (newest / oldest / name), offset "Load more", and entries that
appear and disappear live across sessions.

**Reposts** work on public posts only and distribute the post into the
reposter's followers' feeds; while reposts exist the author cannot restrict the
post's audience (the composer pins it to Public, `Vutuv.Posts.update_post/2`
enforces it) but can always delete the post. In a follower's feed the reposters
they follow collapse behind one card's avatar stack (see the feed section
above), so a widely-reposted post is one entry, not one card per reposter.

## Replies (threads)

A reply is a **normal post** (own permalink, audience, images, tags,
likes/reposts/bookmarks, shows up in the replier's feed and profile) plus a
`post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`) **and the
thread root** (`root_post_id`, denormalized at creation — threading is
otherwise only a parent-pointer chain — so "all replies of this thread" is one
indexed lookup; it feeds the thread-participation notifications, see
[realtime.md](realtime.md)). The root reference nilifies when the root post is
deleted.

Replying works on **public** parents only (the reply button on restricted posts
is disabled, like repost) and pins the parent's audience open like reposts do.
Replies to replies are allowed.

**Quoting a passage** (issue #1114). Marking part of a post and then pressing
that post's Reply opens the composer with the marked text already in it as a
Markdown blockquote, so a long post can be answered point by point. The whole
mechanism is the Reply link the card already has — no floating menu, no new
route, nothing stored: `assets/js/app.js` reads the selection at click time and
appends it as a `quote` query parameter, and `VutuvWeb.PostLive.Reply` runs that
untrusted string through `VutuvWeb.Markdown.blockquote/1` (trim each line, keep
the quote marker across blank lines, cap at 500 characters cut back to the last
whole word) into the composer's `initial_body`. The server marks the two halves
the client needs: `data-post-body` on a post's prose and `data-quote-reply` on
the enclosing card, naming its Reply control by id. Because thread cards nest,
the card is resolved from the **selection** (innermost marked ancestor), not
from the link — otherwise a marked reply would quote itself into its parent's
answer. A restricted post carries no marker (its Reply control is a dead span),
and the reply page's own parent preview passes `quotable={false}`, since its
Reply link leads back to the page being composed on and would discard the draft.
The quote is plain Markdown in the answer's body; the attribution is the reply
card itself, which already shows the post it answers with its author's avatar
and a link to it.

**A post is rendered by one shared component everywhere**
(`VutuvWeb.PostComponents`): `post_thread_entry/1` shows a reply as a **nested
conversation** — the posts it answers are stacked **above** it as full cards
(each keeping its own like/repost/bookmark bar), with a **connector line that
runs from each avatar into the avatars of the replies it got** (a vertical drop
down the card, then an elbow curving into the next avatar) and every reply
**indented one step further right** under the post it answers, so the thread of
a whole multi-post, multi-author conversation reads at a glance, instead of the
feed's old flat "Replying to @handle" text banner.

**A conversation is a tree, not a timeline** (issue #1027).
`Vutuv.Posts.thread_forest/1` nests the visible posts by their parent pointer
(roots and siblings oldest first) and `thread_order/1` is its depth-first walk —
the reading order every surface uses. Rendering a branching thread flat and
chronologically put a reply written hours after a busy branch point under a
stranger's post, where it read as answering that one. A post answered twice
therefore branches: the spine keeps running past the first answer's whole
subtree down into the next, and only the last sibling closes it with the
rounded elbow.

Indentation is capped at 2 levels (`@thread_indent_cap`) so a deep thread can't
scroll a phone sideways; past the cap replies stay in the same column and the
connector is a straight vertical drop. There the nesting can no longer say who
answered whom, so the "Replying to @handle" banner comes back for every card
that is *not* the first answer under its parent (`reply_banner?/4`) — a forest
root, whose parent is off the page, keeps it at any depth.

On the feed and the profile Posts section `Vutuv.Posts.collapse_threads/1` folds
each visible chain: it drops the ancestors' own standalone rows (so a middle
post is no longer shown twice) and hands each surviving leaf its
`:ancestors`, which the component nests into the same tree, so however many
posts, authors or branches a thread spans it renders once; the archive and saved
lists fall back to nesting the single direct parent.

All read the same (each a single card of flat `divide-y` rows).

The notification page reuses the compact `post_preview/1` for the post a
like/reply quotes.

**The permalink page renders the conversation as an embedded LiveView**
(`VutuvWeb.PostLive.Thread`, `live_render` from `PostController` — the
profile's pattern: the controller keeps the URL and the agent-format
negotiation, the socket owns the conversation card). A **page's** post permalink
(`/organizations/:slug/posts/:id`) hosts the same LiveView, nested one level
deeper inside `VutuvWeb.OrganizationLive.Post`: it needs the identical thread now
that a page's post can be answered (#1336), and one owner beats a second
rendering — the page's earlier hand-rolled card plus a read-only remote-reply
list had no expanders, no batched action bars, and a ⋯ menu whose `phx-click` its
host did not answer. A **small conversation
(≤ 25 visible posts) renders whole** (issue #1006) in `thread_order/1` reading
order via `PostComponents.thread_conversation/1`. A **bigger one opens as a
window around the permalinked post** (`Vutuv.Posts.thread_window/3`, the issue
#1033 follow-up — a 131-post thread used to dead-render ~930 KB of HTML with
one embedded action-bar LiveView per card): the root pinned on top, a
"Show N earlier posts" expander over the elided middle, the 3 nearest
ancestors, the post itself, the first 20 posts of its **own reply subtree**
(a reading-order prefix, so every shown reply's parent is on the page) and a
"Show N more replies" expander; sibling branches stay off the page but are
counted in a "part of a conversation with N posts" line linking to the root's
permalink ("Read it from the start"). The expanders are plain `phx-click`
events that widen server-side budgets and re-query — no custom JS. The window
is computed on an id-only skeleton of the conversation (one `root_post_id`
query, hard-capped at 1000), so only shown posts get loaded and preloaded; the
degraded floor (deleted root nilified the links: surviving chain + direct
replies) windows the same way. Inside the host the action bars are the
in-process `ActionsComponent`; the thread subscribes to each **shown** post's
counter topic and forwards `{:post_counters, …}` via `send_update`
(`ActionBar.apply_counters/2`), so the permalink keeps live counters at one
process per visitor, bounded by the window instead of the conversation.

The permalinked post is the tinted `:full`-mode card (`#thread-focus`; an
absolutely positioned `::before` so the connector geometry is untouched) and,
when it has context above, app.js scrolls it into view on arrival
(`data-thread-scroll`) — for a person, not for the link screenshot browser,
whose capture that jump left blank (issue #1033; see the URL-screenshot
section of [images.md](images.md)). A post with no thread renders standalone
exactly as before. The parent's author gets a derived "replied to your post"
notification (self-replies excluded). The agent-format siblings deliberately
keep the **whole** conversation (`Vutuv.Posts.list_thread/3`, capped at 200):
an agent reading `.md` has no expander to click, so `PostDoc` carries the full
`thread` in the same reading order (each entry with its parent pointer **and**
its nesting `depth`), which the md renderer turns into a heading level per
step and the txt renderer into two spaces per step.

A reply **outlives its parent**: where the parent is gone the card falls back to
a banner (which names the account as `@handle`, never the clear name) that
degrades from "Reply to a now-deleted post by @handle" (profile link) to a
nameless "Reply to a deleted post" once the account is gone too — no name is
retained past account deletion.

## Post images

Post images are uploaded eagerly in the composer (abandoned uploads are swept
after a day), up to 10 per post, 50 MB each (`jpg/png/webp`, plus `heic` when
the libvips build can decode it — capability-detected via
`priv/heic_probe.heic`). The 50 MB ceiling must stay below the endpoint's
multipart limit (64 MB, `VutuvWeb.Endpoint`) and nginx's `client_max_body_size`
(64 m, see `docs/ADMINS.md`).

A post body may embed its uploads **inline**: `![alt](/post_images/<token>/<version>)`,
optionally with an alignment fragment (`#left` / `#right` float beside the
wrapping text, `#center`, no fragment = full text width).
`VutuvWeb.Markdown.render_post/2` renders **only** the post's own attachments
(marker swap before the pipeline, injection after; the fragment becomes a
`post-inline-image--*` modifier class and never reaches the served URL) and
drops every other `<img>` — a hotlinked remote picture would leak each
reader's IP, so `Vutuv.MarkdownContent.validate_own_images_only/2` in
`Post.changeset` also rejects any non-own-upload `![](…)` at write time (the
composer and `POST /api/2.0/posts` alike — a 422 for the API). In the composer,
files can be dropped/pasted straight into the prose or picked via the 🖼
toolbar button (both insert at the cursor once uploaded, via the
`mde-image-uploaded` / `mde-insert-image` push events), each thumbnail row has
an explicit "Insert into text", and selecting an image in the editor reveals
the alignment buttons. Attachments the body does **not** reference render as
the gallery / image tile row below the post (`VutuvWeb.PostComponents`
de-duplicates via `PostImage.referenced_in?/2`); **both** full mode and
previews render inline references in place (previews via the
`.post-clamp--media` height clamp — see the preview-truncation section).
Anonymous surfaces (RSS, ActivityPub, JSON-LD, agent docs) inline only
AI-**released** images. Direct messages stay
image-free (`Vutuv.MarkdownContent.validate_no_images/2` in
`Vutuv.Chat.Message` + [messages.md](messages.md)), as do organization and
job-posting descriptions.

All served versions are AVIF (see [images.md](images.md)), EXIF-autorotated and
**metadata-stripped** (no GPS leaks); the original keeps its metadata in the
private `originals/` tree and is never served.

Every image byte goes through the authorizing proxy `GET
/post_images/:token/:version` (`VutuvWeb.PostImageController`), so a post's
audience guards its images too — served with `send_file` everywhere (the
X-Accel-Redirect handoff was disabled after it failed in production). The
serving mechanics (version parser, send_file / X-Accel switch, cache header)
live once in `VutuvWeb.ImageProxy`, shared with the job-posting and
organization image proxies; this controller keeps the post policy, the
on-the-fly `og.jpg` and the download filename.

Legacy `…/feed.webp` URLs in old post bodies keep resolving.

## Photo posts (issue #1104)

Not a second kind of post — the same post, showing its pictures properly.
Everything beyond "drop photos, press Post" is one switch or one select.

### One composer, no tabs

A post is one kind — photos are optional attachments on it — and the composer
says so. The Text|Fotos tabs it used to have made the same stored post *feel*
like two kinds, with the questions asked diverging per tab, so they went:
`PostLive.Composer` has no mode, and every arrangement decision keys on
**whether photos are attached**.

The **editor is always on top**. Attached photos always render as the
**large grid** below it (adding more photos is a tile in the grid, and with
no photos yet the picker is the bottom row's "Add photos" label — exactly
one upload input renders, and both carry the same `composer-add-photos` id,
which is how the feed's camera button finds its target). Tiles keep the photo's **own aspect ratio** (inline
`aspect-ratio` from the stored dimensions — the author judges the upload by
the full frame, never a square crop). Under every tile sit the things a
photographer looks for and would not find behind a gear icon: **one caption
input** (it doubles as the accessible name via `photo_alt/1`, so the alt
input stays an opt-in refinement in the panel rather than a second
required-looking field) and, when the file carries camera facts, the **"Show
camera settings" switch with the very line visitors would see**. **The
picture itself is the options button** (a real `<button>`, so keyboard users
reach the panel too); the old four-button bottom scrim is gone — with a
single photo it was two dead arrows plus a ⚙ the picture-tap covers. What
remains on the tile: a remove dot top-right and the crop dot bottom-center.
Reordering is **pointer drag on the tile itself** — mouse and touch alike
(hold a tile briefly on touch to lift it; the ◀ ▶ arrow dots that used to be
the touch path are gone, on Stefan's ask). The
licence and download pair folds behind the **"Photo details" row** (see
below). The cover badge appears only from the second photo on, and the amber
ALT nudge only while a photo has **neither** caption nor alt.

Entry points: the feed's trigger row offers the pill and a camera button —
both open the **same** composer; the camera button additionally chains a
`JS.dispatch` click onto the composer's "Add photos" control (the label
exists in the hidden panel), so the native photo picker opens in the same
gesture, and a browser that refuses the scripted click still lands in a
composer with that control in view.

**The ✕ always collapses and keeps the draft** (issue #1135) — the
server-side draft (issue #1148) keeps the photos too, and the feed re-opens
over a held draft, so nothing ever sits invisibly behind the collapsed
panel. Really throwing a draft away is its own control: the header's
**"Discard draft"** button, shown only while there is something to lose,
behind a confirm (`discard-draft` → `{:composer_discarded, id}` to the
feed); the restore notice's button shares the handler.

**Photos survive a reconnect.** The attached rows ride the form as hidden
`post[image_ids][]` inputs; a re-mounted composer re-adopts the recovered,
still-pending rows (`Posts.pending_images/2` — own, unattached rows only, so
a stale or hostile id list can neither steal a photo nor resurrect a removed
one). This is the photo half of issue #1130: the pending rows survive in the
DB, only the socket state died. A photos-only draft also counts as drafting,
so the feed re-opens the collapsed composer over it.

### Drop anywhere, crop to a shape, arrange the bento

**The whole composer form is the drop zone** (`phx-drop-target` on the form,
not on the photo grid — a nested second zone would steal the active state):
photos can be dragged in from the first drag on, before any grid exists.
LiveView stamps `phx-drop-target-active` on the form while files hover it,
and two `components.css` rules use that class to reveal the "Drop photos to
add them" overlay (the markup carries no competing display utility — the
#880 lesson). A drop **into the prose editor** stays different on purpose:
the editor's ProseMirror handler swallows it (now with `stopPropagation`, or
the same drop would also bubble to LiveView's window listener and upload
twice) and inserts the picture inline at the drop point.

**The ratio crop** (`Vutuv.Uploads.Crop` fractions, the avatar/cover
machinery reused). Every tile carries a crop dot; it opens the
`assets/js/photo_crop.js` dialog — the avatar modal's pan/zoom interaction
plus a chip row of the popular shapes (1:1, 4:3/3:4, 3:2/2:3, 16:9/9:16;
deliberately no freeform handle) and pinch-zoom for touch. The dialog loads
the **author-only `source` workbench**
(`GET /post_images/:token/source.avif`, `PostImageStore.source_path/1`: the
uncropped frame at feed size, derived on demand from the kept original,
cached in the private originals tree, 404 for everyone but the author), so a
photo that is already cropped still shows its whole frame to re-crop from.
"Apply" pushes `photo-crop` to the composer; `Posts.crop_image/2` +
`PostImageStore.apply_crop/2` re-derive **every served version** from the
original with the crop applied, persist the fractions in `post_images.crop`
(the Regenerator re-applies them — without that a re-derive would silently
un-crop everyone) and set `width`/`height` to the served (cropped)
dimensions, which is what the mosaic and the `<img>` attributes read.

Once a crop exists, **the uncropped picture leaves the server on no path but
the workbench**: the served versions and lightbox `xl` show the crop, the
`og.jpg` derive re-applies it, and the original download serves a
full-resolution cropped JPEG (`cropped.jpg` beside the original, dropped on
re-crop) — the exact-file choice is forced off and blocked while cropped
(`download_exact`), because the upload still shows what the author cut away.
The proxy's cache header is immutable, so `PostImage.url/2` appends a
crop-keyed `?v=<hash>` buster while a crop is set (bodies stored under an
older buster keep resolving: the inline-image whitelist strips `?v=` before
lookup).

**The bento workshop** appears with the second photo: a live preview
rendered by the very `mosaic_layout/2` the feed uses, plus pattern chips —
each chip draws its arrangement's real 12×6 geometry in miniature from
`Vutuv.Posts.GalleryLayout`, the named catalog the old hardcoded
`mosaic_shape` clauses moved into. "Auto" (nil) is the default and keeps the
orientation-driven choice bit for bit; a chosen name is stored in
`posts.gallery_layout` (cast through `GalleryLayout.cast/1`, unknown names
mean auto), rides the draft (`post_drafts.layout`) and falls back to auto at
counts where the name does not exist, so removing a photo never invalidates
a post. The frame stays orientation-tuned even for a chosen variant — the
variant names where the tiles sit, the frame keeps the hero cell near the
hero's own shape. Swapping photos in the preview is **tap-tap** (`mosaic-swap`:
first tap marks, second trades places), which needs no drag and therefore
works identically on a phone; the grid reorders by pointer drag (below).

The workshop also owns the **fit pair** ("Whole photos" / "Fill the tiles",
`mosaic-fit`): by default the mosaic shows every photo **whole**, letterboxed
inside its tile (`object-contain` — nobody's picture loses its edges
unasked); "fill" switches the tiles to the old `object-cover` behaviour,
where the photo covers its tile and is cropped by it. Stored as
`posts.gallery_fill?` (default false — which deliberately flips existing
posts to whole-photo rendering too, decided 2026-07-30), drafted as
`post_drafts.fill?`. The orientation-tuned frames matter in both modes: they
minimise the letterboxing exactly where they used to minimise the crop.

### The photo waits, the post does not

A post carrying a picture that has not finished the AI image scan publishes
straight away. The **picture** is what waits: for anyone but the author and
admins it renders as a placecard tile with a turning hourglass, saying the check
is running and the photo will appear there by itself, and it does — over PubSub,
with no reload.

It shipped the other way round, holding the post back whole (out of every feed
and profile, off its own permalink) on the argument that publishing the text
would mean the post is *seen* before it is vetted. The case that showed the unit
was wrong: somebody answers your post with a photo, you get the "X answered you"
notification, and the reply is nowhere you can look — not on the permalink, not
in the notification's own quote. The scan is about the picture, and an unvetted
picture is rendered nowhere either way: every machine surface (agent formats,
RSS, OG, JSON-LD, the Fediverse Note) is built from `Posts.released_images/1`,
and the Fediverse has its own delivery hold (`FEDIVERSE_IMAGE_HOLD_SECONDS`) so
a Note goes out with its picture rather than without it.

So `Posts.moderation_hidden?/1` and `scope_unfrozen/2` (its SQL twin) gate on
`frozen_at` and the author's account standing, and on nothing else.
`posts.images_pending?` lives on as the flag behind `Posts.held_for_image_check?/1`
— what the **author's** amber progress panel keys on
(`PostComponents.photo_check_progress/1`: "your post is published, the photo is
not there yet", the hourglass, and a count on a multi-photo post). It is a
denormalised flag on purpose: it is read per rendered card, and a `NOT EXISTS`
over `post_images` per card would be paid for on every one.
`Posts.refresh_images_pending/1` is its one owner and runs at the three moments
it can change — create, edit, scan settles — with a guarded `update_all`, so two
scans finishing at once cannot both claim the settle.

`{:new_post, …}` therefore fans out once, to everybody the post is addressed to,
the moment it is written. When a verdict lands,
`Posts.broadcast_images_settled/1` announces it on the post's own topic and on
the author's activity topic. Between them those reach every open surface: the
permalink's conversation and the saved list subscribe per shown post, the
profile page's visitors subscribe to the profile owner, and the feed subscribes
to the few cards on it that are actually waiting
(`PostLive.Feed.watch_pending_photos/2` — keyed on `held_for_image_check?/1`, so
in steady state it holds nothing).

**A single photo is shown whole in the feed.** `PostComponents.feed_photo_fit/1`
answers `:whole` for every shape but one, and the image is bounded by height
rather than cropped, so a portrait occupies a narrower centred column instead of
losing its top and bottom to the old 24rem `object-cover` box. The exception is
a photo **taller than 1:2**, which at column width is a scroll rather than a
picture: that one crops to `3 / 4`, and the permalink still shows it whole.

**Width has no such limit, and the asymmetry is deliberate.** A wide photo used
to crop to `2 / 1` on the mirror argument that a panorama at column width is a
letterbox slit. It is not: the column bounds the width, so a wide frame is
merely flat and costs the timeline nothing. The crop, on the other hand, always
cost content off the right-hand edge — a 1572×424 screenshot of a news teaser
lost its headline and teaser text in the feed while the permalink showed them,
which reads as two renderings of one post rather than one. Height is a budget
the card has to defend; width is not.

**In the feed, two or more attachments lay themselves out as an aspect-aware
bento mosaic** (`VutuvWeb.PostComponents.mosaic/1`). The first photo is the
hero and gets the big tile, so **ordering leads the layout** — pointer drag in
the composer's grid (the PhotoStrip hook: lift on first mouse movement, or
after a short still hold on touch, so scrolling over the photos keeps
working), or the bento preview's tap-tap swap. At most five tiles show; the rest fold into a `+N` on the
last one, and the block is height-capped, so a photo essay costs the same
timeline height as a snapshot. The layout table is `Vutuv.Posts.GalleryLayout` on a
12×6 grid; what it tunes is the **hero cell's** aspect, not the frame's (a
cell's shape is `frame × cols/12 ÷ rows/6`, so the two pull in opposite
directions). `mosaic_layout_test.exs` asserts both the tiling and the hero
shape.

**On the permalink the photos keep their natural aspect ratio** — no crop — and
a click opens the **lightbox** (`assets/js/lightbox.js`): the `xl` version
(2560 px, added for this), caption, camera panel, download and licence, with
←/→/Esc and swipe. The overlay is appended to `<body>`, deliberately outside
every LiveView root: the permalink's conversation is a LiveView, and an overlay
inside it would be re-rendered away by an unrelated counter tick. It reads the
gallery links' `data-photo-*` attributes, so there is one copy of every fact;
with JS off those links are plain hrefs to the full-size image.

**Per photo** (`Posts.update_image_settings/2`, panel in
`PostLive.Composer.photo_panel/1`): a `caption` (shown to everyone; distinct
from `alt`, which describes the picture for people who cannot see it), a
**camera-settings** switch (renders from the DB columns — the served files stay
metadata-stripped) and, for a set of several photos, the **download override**
with its one follow-up, which file (see [images.md](images.md)). The caption
and the camera switch live inline under the tile, not in the panel (two
same-name inputs would corrupt the submit); the panel keeps the alt input and
the override. It expands below the grid rather than floating — a popover on a
phone covers what it is about and has nowhere to put a follow-up. An "apply to
all photos" shortcut copies the two switches (never the texts: a caption
describes one picture).

**Per post**, the two questions about the pictures themselves — who may reuse
them, and what a visitor can save — fold behind the collapsed **"Photo
details" row** that appears with the first photo. Someone stapling a
screenshot to a text is not publishing pictures: making them rule on reuse
rights and original files is two answers they do not have as the price of an
ordinary post (the spirit of issue #1157), so the fold names the answers in
force (licence label + download label) and can simply be ignored, while a
photographer is one tap away. A post saved with the row folded keeps the
author's default licence and the web-versions-only download; the selects
render only while the row is open, so an edit that never rendered them
cannot reset the stored answers (`save` falls back to the assign).

The first is **what a visitor can save**: the served AVIF versions only (the
default), the full-resolution original with its metadata removed, or the
uploaded file byte for byte. The columns behind it are per photo
(`download_original` + `download_exact`), but the select answers for the whole
set, because that is how a photographer decides it — a single photo therefore
gets no switch in its panel at all, and a set whose photos disagree (a panel
override, an older post) reads "Different per photo" rather than claiming an
answer nobody gave. The select carries its own `phx-change` instead of riding
the form's `validate`: every keystroke replays the whole form, and a replayed
value would push the select's answer back over a per-photo choice just made in
the panel. Picking the exact file names the location it hands over when any
photo carries one, and a format `Vutuv.Uploads.MetadataStrip` cannot take apart
says so up front rather than quietly serving an uncleaned file under the
cleaned label (`Posts.update_image_settings/2` forces the exact file there).

The second is the licence: one `Vutuv.Posts.PhotoLicense` from a fixed
vocabulary (`arr` default, CC BY / BY-SA / BY-NC / CC0 4.0). The last pick is
remembered on `users.default_post_license` and pre-selected next time, so a
professional sets it once. It renders as a line
under the photos **only when it grants something** — a rights notice on every
picture in the app teaches people to stop reading the one that matters. It also
reaches machines: the agent-format siblings carry the SPDX id, and the JSON-LD
publishes each photo as an `ImageObject` with `license` /
`acquireLicensePage` / `creditText`, which is what makes an image-search result
licensable.

## Link screenshots

A post that carries **exactly one URL and no image attachment** gets an
auto-generated screenshot of the linked page, captured off the request path so
the save is never slowed. The subsystem is `Vutuv.Posts.Screenshots` with the
`post_screenshots` table (one row per post, unique `post_id`), which is **both
the durable queue and the attachment record**: a `pending`/`capturing`/`failed`
row is work, a `ready` row carries the stored screenshot.

The queue serves **two owners**: a member's post (`post_id`) and a cached
fediverse post from a followed account (`remote_post_id`,
`Vutuv.Fediverse.RemotePost`; a check constraint enforces exactly one). The
remote side's qualifying rule, wiring and cleanup live in
`fediverse.md` ("Their link screenshots"); everything below — worker, probe,
YouTube branch, retries, moderation, admin views — is shared.

Some links are deliberately **not** screenshotted. Two are caught in
`qualifying_url/1` (a pure, no-network check on the request path, so no row is
ever created): a link to *this* installation's own **`/settings`, `/admin` or
`/system`** area — the host is derived from `VutuvWeb.Endpoint.host()`, never a
literal `vutuv.de`, so it holds on any installation, and a shot of those pages
would only ever be a login redirect or an internal page — and a link to a
**blocklisted page** (`Vutuv.ScreenshotBlocklist.blocked?/1`, the admin-edited
list at `/admin/screenshots?tab=blocklist`, seeded with `reddit.com` and
`heise.de`). Those sites answer a headless capture with a cookie banner, a
login wall or a bot check, so the shot is always a picture of a dialog;
skipping them spends no Chromium run at all, and the post simply shows its
link. Entries are domains or URLs — see
[images.md](images.md) for the grammar. The same blocklist gates the
profile-link previews inside `capture_framed/2` (returning `:blocklisted`, a
permanent outcome).

**A YouTube video link stores YouTube's own thumbnail instead of a capture.**
The watch page answers every logged-out request with the cookie-consent
interstitial, so a screenshot of it only ever shows the banner.
`Vutuv.YoutubeThumbnail` recognises a video URL (watch / `youtu.be` / shorts /
live / embed on any of YouTube's hosts, parsed by host + path segments, never
a string prefix), confirms the video exists via the keyless oEmbed endpoint
(so a deleted or private video falls through instead of storing YouTube's grey
placeholder tile), and fetches the static `maxresdefault.jpg`, falling back to
the always-present `hqdefault.jpg`. The bytes are stored through the same
uploader **without the browser frame** (the thumbnail is the video's artwork,
not a web page) and enter AI image moderation like any capture; readers only
ever see our stored copy, never `img.youtube.com`, so no viewer IP reaches
Google. Any failure — unknown video, network trouble, a non-image answer —
falls back to the ordinary capture below. Tests stub the fetch via the
`:youtube_thumbnail_req_options` seam; the one-shot backfill that re-queued
the pre-existing banner captures is `Vutuv.Release.requeue_youtube_screenshots/0`
(`Screenshots.requeue_youtube/0`).

A link that does **not answer a plain HTTP 200** is rejected at capture time by
`ensure_http_ok/1`, a `redirect: false` GET probe the worker runs before Chromium
(GET, not HEAD, so a server that 405s HEAD on a real 200 page isn't wrongly
skipped; an internal host is caught here as `:internal_target` and never probed,
so the probe is not an SSRF request). Only a `200` is captured — a redirect, a
404 or any other status just shows the plain link. Reasons split permanent from
transient for the retry cap: a `3xx` (`:redirect`) and a `4xx` (`{:bad_status,
status}`) are permanent (they won't become a 200 for this URL), while a `5xx`
(`{:server_error, status}`) and an unreachable probe (`:probe_failed`) are
transient and retry with backoff — the durable-queue `permanent_failure?/1`
decides. The probe's Req options come from the `:post_screenshot_req_options`
app-env seam (tests inject a `plug:`).

`Vutuv.Posts.create_post/2` / `create_reply/3` / `update_post/2` call
`Screenshots.reconcile/1`, which enqueues, refreshes (URL changed) or drops
(no longer qualifies) the job to match the post. `Vutuv.Posts.ScreenshotWorker`
(a GenServer poller modelled on `Vutuv.Fediverse.Deliverer`) drains due jobs:
`nudge/0` captures a fresh post at once, a slow poll catches retries, and on boot
`resume_stuck/0` re-queues anything a crash left mid-capture — so a restart or
re-deploy loses nothing and a missing screenshot is re-created. Transient
failures retry with exponential backoff up to a cap, then `failed`; an
SSRF-refused internal host fails permanently (like a profile link's `broken?`).

Chromium is bounded twice, because a page can hang the capture in two different
places. The driver's own deadline (`Vutuv.PageScreenshot.Cdp`, 20s from
navigation) stops waiting on a page whose network never goes quiet — GitHub's
issue search is one — and photographs what has rendered by then. The OS
`timeout` wrapper (30s) then force-kills a Chromium that answered and hung
anyway, and a `Task.yield` behind that catches a driver the first two miss. See
the URL-screenshot section of [images.md](images.md) for how the wait adapts to
a consent dialog in between.

Capture is **DRY** with the profile-link previews: `Vutuv.PageScreenshot`
(`capture_framed/2`, the shared Chromium + browser-frame + SSRF pipeline) and
`Vutuv.Screenshot` storage (the row is the scope, so it is the same 400×264 AVIF
thumb with the `/images/screenshot.png` fallback). Everything is gated by the
`:generate_screenshots` flag (air-gapped installs queue nothing).

`VutuvWeb.PostComponents` **floats** a ready screenshot to the body's top right
(`float-right w-2/5 sm:w-1/3`) and the text wraps around it — the same reading in
the feed/profile preview and on the permalink, so a single-link post looks like
itself everywhere. The preview additionally needs the float-wrap body clamp
(`link_screenshot_layout?/2` → `.post-clamp--wrap`, since `-webkit-line-clamp`
cannot wrap around a float); full mode has no clamp and simply renders the
screenshot as the body div's first child. On capture the worker broadcasts
`{:post_screenshot_ready, …}` to the author's + followers' activity topics, so an
open feed/profile upgrades the card with no reload. Admins watch the queue and
browse the gallery (each shot linked to its post, paginated) at
`/admin/screenshots` (`VutuvWeb.Admin.ScreenshotLive`), and hand a `failed` job
back to the worker there ("Retry" → `Screenshots.requeue/1` + a worker nudge).
That button is the only way past the retry cap: a job that burned its attempts
while capture itself was broken is never picked up again on its own.

The author can **remove a bad screenshot** (a cookie-banner-covered capture,
say) from the post edit page (`VutuvWeb.PostLive.Edit`): the "Remove screenshot"
control shows only while a captured, released screenshot is on the card, and
`Vutuv.Posts.dismiss_screenshot/1` → `Screenshots.dismiss/1` purges the files and
tombstones the row as `dismissed`. A `dismissed` row renders nothing, the worker
skips it, and `reconcile/1` leaves it in place for the same URL, so a plain
re-save never re-captures it (changing the URL still re-captures; dropping the
link cancels the row). It broadcasts `{:post_screenshot_removed, …}` so open
feeds/profiles drop the card live, and is excluded from the admin queue/gallery.

## Book and film reviews

A post can carry a structured **review sidecar** (`Vutuv.Posts.PostReview`,
table `post_reviews`, one per post): `kind` (`book`/`movie` — open for future
kinds), an `identifier` (a checksum-validated ISBN-13 via `Vutuv.Isbn`, or an
IMDb `tt…` id extracted from a pasted URL), cached display metadata (`title`,
`creator`, `year`), the edition details fetched with the cover (`pages`,
`publisher`, and `duration_minutes` for an audiobook — all set by
`Vutuv.Posts.ReviewCovers`, never cast from params, and cleared when the ISBN
changes) and an optional `medium` (book:
print/ebook/audiobook,
movie: cinema/streaming/disc — "I listened to the audiobook"). The body stays
plain Markdown; *"this post is a book review"* is simply *"the post has a
review row"*, never body parsing. **The composer's review form (the 📖/🎬
triggers, the panel, the ISBN prefill lookup) was removed 2026-07-30** — no
new reviews can be created from the UI, but every stored review keeps
rendering, and the cover/edition background pass keeps serving existing cards.
The changeset seam is what makes that safe: attrs without a `:review` key
leave a stored review untouched, which is exactly what the composer's edit
path now submits.

Every surface that renders the post adds the **review card**
(`VutuvWeb.PostComponents.review_card/1`). It reads top to bottom the way a
book jacket does: the cover (or a kind-glyph tile) with the page count under it,
and beside it the title, the author on the line **directly** below it
("von: …" / "by: …", labelled because between a title above and a publisher
below a bare name is the one line that doesn't say what it is), then
year · medium, the publisher, and the ISBN one size down (`text-xs`) closing
the block. An audiobook's **running time rides the medium in parentheses**
("Hörbuch (ca. 1 Std. 15 Min.)") instead of costing a line of its own. Under
all of it, full width, the dot-separated **links** row — the Open Library book
page first (when a cover is shown, see below), then the store link labelled
with just the store name ("Amazon" / "IMDb") — Amazon for books (built offline
from the ISBN: ISBN-10 `/dp/` link, search fallback for 979 ISBNs; domain +
optional affiliate tag are config, an empty `AMAZON_DOMAIN` removes the link),
IMDb for films. Every line of the identity block is a span of **one** paragraph
and the title carries `mb-0`, because the legacy `components.css` `p` rule
(`margin-bottom: 15px`) would otherwise open a blank line between each fact.
When the medium is an **audiobook** the
"Hörbuch"/"Audiobook" word is itself a link to Audible
(`PostReview.audible_url/1` — a title + author search, since Audible keys its
audiobooks by their own ASIN, not the print ISBN we store; `AUDIBLE_DOMAIN`
config, an empty value keeps the word plain); the parenthetical running time
stays outside that link and is `whitespace-nowrap`, so a narrow card wraps it
whole instead of splitting it mid-figure. The permalink's JSON-LD becomes
`["BlogPosting", "Review"]` with `itemReviewed` (Book/Movie), and the agent
formats carry a `review` entry / fact line (drift-tested).

Where the card sits depends on the width; **what it shows does not**. Its
content is deliberately breakpoint-free — one cover size, one set of lines,
the author always above year · medium — so a phone and a wide screen read the
identical card; a test asserts that no element inside `[data-review-card]`
carries a `sm:`/`md:`/`lg:` utility. Only the placement is responsive: below
the prose on a phone, and from
`md` up a narrow right-hand **aside** beside it (prose left, card right, both
in one flex row — feed, profile and permalink alike). `md` (not `lg`) so
portrait tablets and small laptop windows get the side-by-side reading too, not
just wide desktops. The card is the row's second child, so the stacked order
below `md` is the old one and no markup is duplicated per breakpoint; a review
post without prose (a photo-only post)
keeps the full-width card, since there is nothing to sit beside. The reader's
line clamp then applies to the narrower prose column, so "Weiterlesen" shows on
posts that used to fit — the clamp mechanics themselves are unchanged.

The stored ISBN is the bare 13 digits; every **human-facing** rendering (the
card, the agent-doc fact line, the federated Note and the RSS item) prints it
hyphenated through `Vutuv.Isbn.format/1`, which splits it into EAN prefix,
registration group, registrant, publication element and check digit using
`priv/isbn_ranges.txt` (the International ISBN Agency RangeMessage, refreshed
with `mix run scripts/update_isbn_ranges.exs`). An ISBN whose ranges are not in
the table renders unhyphenated rather than wrongly split. The machine formats
(JSON/XML doc, JSON-LD `isbn`) keep the bare digits.

**Book covers and edition details** are fetched by ISBN
(`Vutuv.Posts.ReviewCovers`, one background pass), off the request path,
gated by `:fetch_book_metadata` — the flag for every book lookup, including
the composer's ISBN → title/author/year prefill. Three sources feed the card:

- the **cover image** from Open Library's cover API;
- **pages + publisher** from Open Library's *edition* record
  (`Vutuv.BookMetadata.edition_details/1`) — deliberately not the books API
  the composer prefills from, which frequently answers without
  `number_of_pages`. An edition with no count of its own (an audiobook, a
  scan) borrows the **median** count of the work's other editions, so an
  audiobook card can still say how long the book is; the card then marks the
  number as the print edition's;
- an audiobook's **running time** from a library catalogue's SRU interface
  (`Vutuv.AudiobookLength`, MARC field 300: "1 Online-Ressource (2 CDs (ca.
  136 Min.))"). Open Library records no durations, so this is a second,
  German-leaning source — the DNB by default, `:dnb_sru_url` per
  installation, blank to switch it off. Only a review whose `medium` is
  `audiobook` asks. It looks up the review's own ISBN first (exact), and
  when that is the print edition — the usual case — searches the work's
  *spoken-word* editions by title + author and uses the answer **only if
  they agree**. They frequently do not: "Russendisko" has a 73-minute
  reading, an 81-minute radio play and a 125-minute near-namesake;
  "Der Herr der Ringe" spans a radio play and a 59-hour Komplettlesung.
  Records are filtered to RDA content type `spw`, an exactly matching title
  (catalogue non-sorting markers stripped) and no "Hörspiel", must state a
  length, and all surviving lengths must be equal — otherwise the card shows
  none, because guessing which recording was reviewed would print a wrong
  number as fact. A borrowed time stores the ISBN it came from
  (`duration_isbn`), which makes the card render it as "approx." and keeps
  it out of the JSON-LD, where nothing can express approximation.

All three are best-effort — an edition nobody knows details for simply keeps
the card it has, and a failed detail lookup never costs the review its
cover. Not a durable queue on purpose: a cover
is decorative, `cover_status` (`none`/`pending`/`ready`/`failed`) tracks the
fetch, a changed ISBN resets it to `pending` and re-fetches, and a lost fetch
is simply retried on the next edit. The fetched cover is an external image
shown publicly, so it enters the AI-moderation gate like any upload
(`review_cover` kind in `Vutuv.Moderation.ImageSubjects`) and is served
through the authorizing proxy `VutuvWeb.ReviewCoverController`
(`/review_covers/:id/cover-<hash>.avif` — post audience + moderation verdict
checked per request, content-fingerprinted filename, so an outdated cover URL
stops resolving). Files live under `review_covers/<review.id>/`
(`Vutuv.ReviewCover`); post deletion and account deletion purge them.

A cover is the one image vutuv holds that is **not ours**: publisher artwork,
quoted at thumbnail size beside a review (§ 51 UrhG). Open Library passes the
images through and grants no rights to them, so the pipeline is built to keep
that quotation defensible, and the pieces below belong together — don't change
one without the others:

- **only what we show**: one derived version, `box_down 320` in
  `Vutuv.Uploads.Spec`, and — the deliberate exception to the
  `Vutuv.Uploads.Originals` rule — **no private original**. That costs the
  `Vutuv.Uploads.Regenerator` path, so a Spec change is followed by
  `Vutuv.Posts.ReviewCovers.refresh_all/1` (`mix vutuv.review_covers.refresh`
  / `Vutuv.Release.refresh_review_covers()`), which re-fetches by ISBN, paced
  to Open Library's rate limit, and purges pre-v7.122.4 originals;
- **source credited**: the card renders an "Open Library" link (the twin of the
  Amazon link, reading as a book link) to `openlibrary.org/isbn/<isbn>` — first
  on the dot-separated links line (§ 63 UrhG's attribution, and the courtesy
  backlink Open Library asks for), shown only when a cover is;
- **not indexable**: every proxy response carries
  `X-Robots-Tag: noindex, noimageindex`;
- **removable**: a moderation rejection deletes the files, as does deleting
  the post.

Operators who would rather not host third-party covers set
`FETCH_BOOK_METADATA=false` — see the "Book covers on review posts" section in
`docs/ADMINS.md`, which spells the position out for them.
