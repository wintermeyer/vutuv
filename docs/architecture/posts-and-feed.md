# Posts and the newsfeed

Markdown posts, deny-based audiences, the `/feed` timeline, likes / bookmarks
/ reposts, reply threads and post images. Business logic lives in
`Vutuv.Posts` (saving *people* is `Vutuv.Social`).

## Posts and the feed

Markdown posts (up to 20k chars) with images and tags.

An **`@handle` of an existing member is auto-linked** to their profile with the
member's name as a hover tooltip, and a **`#hashtag` is auto-linked** to that
tag's `/tags/:slug` page **only when the tag exists and has at least one visible
member** (so a link never lands on an empty tag page) — everywhere the Markdown
renderer runs (`VutuvWeb.Markdown`: posts, chat messages, ads, the RSS/JSON
renderings), skipping entities typed inside code spans/blocks or existing links
and resolving all of a body's mentions and hashtags in one batched query each.

A **bare `http(s)://` URL is auto-linked too**, with its display text shortened
to host + first path directory — but only *outside* code. Inside a fenced block
or an inline code span a URL is sample text, so it is left verbatim
(`VutuvWeb.Markdown.map_outside_code/2`); rewriting it turned `curl
https://vutuv.de` into visible Markdown link syntax.

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
`highlight_diff_blocks/1` runs right after and turns it into real added /
removed rows (issue #1108, below). That is why the order in `render_pipeline/2`
is `CodeHighlight.render/1` first — the diff renderer then still finds a plain
`<pre><code class="language-diff">` sitting inside the labelled wrapper.

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
…}` / `{:new_repost, …}` broadcasts, and a desktop-only **"Who to follow"** rail
(most-followed members you do not yet follow,
`Vutuv.Social.most_followed_users/1`, live follow — now led by members endorsed
for tags you follow, see below).

`Posts.feed_page/2` merges **three** sources through `Vutuv.FeedPage` (a shared
cursor over independent fetchers): own + followed authors' posts, their reposts,
and — since issue #872 — posts carrying a **tag you follow**
(`feed_tag_items/3`), from authors you do *not* already follow (so following a
tag widens the feed with new voices without duplicating the follow path; muted
and blocked authors stay out exactly as elsewhere). Following a tag lives in
`Vutuv.Tags` — see [social-graph.md](social-graph.md). The feed also carries the
reload-free **"Tags you follow"** rail (chips + a `phx-click` ✕ unfollow).

The composer's body field is the shared **Milkdown WYSIWYG Markdown editor**
(`VutuvWeb.UI.markdown_editor/1` + the `MarkdownEditor` hook, also used by the
message composer). It edits Markdown *source* in place — the field stays a
`<textarea>` and the body is still stored and rendered as Markdown — so nothing
downstream (`VutuvWeb.Markdown`, the `.md`/`.txt`/`.json`/`.xml` siblings)
changes. See `.claude/rules/design.md` for the component and its gotchas.

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
negotiation, the socket owns the conversation card). A **small conversation
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

**A single photo is shown whole in the feed.** `PostComponents.feed_photo_fit/1`
answers `:whole` for every ordinary shape (the envelope is 2:1 down to 1:2, so
4:3, 3:2, 16:9, 1:1 and a phone's 9:16 all qualify) and the image is bounded by
height rather than cropped, so a portrait occupies a narrower centred column
instead of losing its top and bottom to the old 24rem `object-cover` box. Only
the extremes crop — past 2:1 a panorama is a slit at column width, past 1:2 a
tower is something you scroll past — to `2 / 1` and `3 / 4` respectively, and
the permalink still shows those whole.

**In the feed, two or more attachments lay themselves out as an aspect-aware
bento mosaic** (`VutuvWeb.PostComponents.mosaic/1`). The first photo is the
hero and gets the big tile, so **reordering is the only layout control** — drag
in the composer, or the ◀ ▶ buttons, which are the path on touch (HTML5 drag
cannot fire there). At most five tiles show; the rest fold into a `+N` on the
last one, and the block is height-capped, so a photo essay costs the same
timeline height as a snapshot. The layout table is in `mosaic_shape/2` on a
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
metadata-stripped) and an **original download** switch with its one follow-up,
which file (see [images.md](images.md)). The panel expands below the strip
rather than floating — a popover on a phone covers what it is about and has
nowhere to put a follow-up. An "apply to all photos" shortcut copies the two
switches (never the texts: a caption describes one picture).

**Per post**, one `Vutuv.Posts.PhotoLicense` from a fixed vocabulary (`arr`
default, CC BY / BY-SA / BY-NC / CC0 4.0). The select appears only once a photo
is attached; the last pick is remembered on `users.default_post_license` and
pre-selected next time, so a professional sets it once. It renders as a line
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

Some links are deliberately **not** screenshotted. Two are caught in
`qualifying_url/1` (a pure, no-network check on the request path, so no row is
ever created): a link to *this* installation's own **`/settings`, `/admin` or
`/system`** area — the host is derived from `VutuvWeb.Endpoint.host()`, never a
literal `vutuv.de`, so it holds on any installation, and a shot of those pages
would only ever be a login redirect or an internal page — and a link to a
**screenshot-blocklisted host** (`Vutuv.PageScreenshot.host_blocked?/1`, the
`:screenshot_blocked_hosts` config, default `reddit.com`, override with
`SCREENSHOT_BLOCKED_HOSTS`). Those sites answer a headless capture with a
login/consent wall or block bots outright, so the shot is always a useless
placeholder; skipping them (matched on the apex host and every subdomain)
spends no Chromium run at all. The same blocklist gates the profile-link
previews inside `capture_framed/2` (returning `:blocked_host`, a permanent
outcome).

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
places. `--timeout` (`Vutuv.PageScreenshot`, 20s) stops a page whose network
never goes quiet — GitHub's issue search is one — and shoots what has rendered;
without it headless Chromium waits for the load event forever and stores
nothing, and `--virtual-time-budget` does **not** bound this under
`--headless=new`. The OS `timeout` wrapper (30s) then force-kills a Chromium
that took its shot but hung on shutdown. Either way `capture_outcome/2` lets the
**file on disk decide**: a killed run that already wrote the screenshot counts
as a capture, so a finished image is never thrown away (a truncated one simply
fails to frame and retries).

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
review row"*, never body parsing. The composer's 📖/🎬 triggers open the panel;
the hidden `kind` field always submits, so closing the panel deletes a stored
review on save, while attrs without a `:review` key (the API's partial PATCH)
leave it untouched.

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
