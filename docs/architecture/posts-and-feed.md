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
`Vutuv.Social.most_followed_users/1`, live follow).

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
link to the permalink (no length metric — issue #880 dropped the word count as
meaningless once the reader has the preview). The line budget is a **per-reader,
per-breakpoint preference** (`Vutuv.Accounts.User.post_prefs/1`, set on the
language & maps settings page): desktop and mobile independently, default 6 lines
on desktop / 8 on a phone. The reader's values ride onto the post body as the
`--post-clamp-desktop` / `--post-clamp-mobile` custom properties
(`VutuvWeb.PostComponents.post_body_style/1`, which stays `nil` for a
default/logged-out reader so their DOM carries no inline style and the CSS
fallbacks apply); `.post-clamp`'s `@media (width < 48rem)` rule swaps the mobile
value in. A `0` (or a cleared, nil) count means **no truncation** on that
breakpoint (`-webkit-line-clamp: none`); when the reader disabled truncation on
**both** breakpoints the card renders the whole body uncut like `:full` (no
character cap, no clamp, no "Read more"). Hyphenation of the post body is the same
kind of per-reader, per-breakpoint preference (`--post-hyphens-*`; the CSS
fallbacks reproduce the historical default of off on desktop, on for the narrow
phone column). Very long bodies are otherwise cut server-side at a block boundary
(`VutuvWeb.Markdown.render_preview/2`, ~1000 chars) — that case reveals the link
with no JS. A longer body that merely
overflows the CSS clamp can't be detected on the server (wrapping is
width/font-dependent), so the link ships hidden and the `PostPreviewClamp` JS
hook (a `[data-post-preview]` sweep on classic pages, re-run on resize and
`document.fonts.ready`) reveals it — but only when the clamp actually hides more
than ~one line. It measures that by reading the clamped `clientHeight` (the
painted height), then dropping the node to `display: block` for one synchronous
read of its natural `scrollHeight`; the difference is the amount hidden. It does
**not** read `scrollHeight` off the clamped node, because `.post-clamp` renders
as `display: -webkit-box`, whose `scrollHeight` WebKit/Safari over-reports on a
fully-visible post — that over-report sprouted the false "Read more" of issue
#880, and it clears any pixel threshold, so the earlier threshold-only fix did
not hold on Safari; measuring the natural block height sidesteps the buggy number
entirely. With JS off such a card keeps the native line-clamp ellipsis. The
permalink (`mode={:full}`) never clamps.

The profile page and the archive show the author's timeline (posts + reposts).

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

Every post card carries a live action bar (`VutuvWeb.PostLive.Actions`, one
embedded LiveView per card via `live_render`), so the like/repost/bookmark
counters tick in real time on the feed *and* on classic pages (permalink,
profile, archive).

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
`post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`).

Replying works on **public** parents only (the reply button on restricted posts
is disabled, like repost) and pins the parent's audience open like reposts do.
Replies to replies are allowed.

**A post is rendered by one shared component everywhere**
(`VutuvWeb.PostComponents`): `post_thread_entry/1` shows a reply as a **nested
conversation** — the posts it answers are stacked **above** it as full cards
(each keeping its own like/repost/bookmark bar), oldest-first, with a
**connector line that runs from each avatar into the reply's avatar** (a
vertical drop down the card, then an elbow curving into the next avatar) and
every reply **indented one step further right** under the post it answers, so
the thread of a whole multi-post, multi-author conversation reads at a glance,
instead of the feed's old flat "Replying to @handle" text banner.

Indentation is capped at 2 levels (`@thread_indent_cap`) so a deep thread can't
scroll a phone sideways; past the cap replies stay in the same column and the
connector is a straight vertical drop.

On the feed and the profile Posts section `Vutuv.Posts.collapse_threads/1` folds
each visible chain: it drops the ancestors' own standalone rows (so a middle
post is no longer shown twice) and hands each surviving leaf its ordered
`:ancestors`, so however many posts or authors a thread spans it renders once;
the archive, saved lists and permalink fall back to nesting the single direct
parent.

All read the same (each a single card of flat `divide-y` rows).

The notification page reuses the compact `post_preview/1` for the post a
like/reply quotes.

The permalink page lists the visible replies oldest-first (nesting off there —
the parent is the page itself), the action bar carries a live reply counter, and
the parent's author gets a derived "replied to your post" notification
(self-replies excluded).

A reply **outlives its parent**: where the parent is gone the card falls back to
a banner (which names the account as `@handle`, never the clear name) that
degrades from "Reply to a now-deleted post by @handle" (profile link) to a
nameless "Reply to a deleted post" once the account is gone too — no name is
retained past account deletion.

## Post images

Post images are uploaded eagerly in the composer (abandoned uploads are swept
after a day), up to 10 per post, 6 MB each (`jpg/png/webp`, plus `heic` when the
libvips build can decode it — capability-detected via `priv/heic_probe.heic`).
Attachments are shown as a **gallery** below the post; post **bodies never embed
images inline**. Two guards, one at each end: `Vutuv.MarkdownContent.validate_no_images/2`
in `Post.changeset` rejects a body with image Markdown (`![](…)`) on every write
path (the composer and `POST /api/2.0/posts` alike — a 422 for the API), and
`VutuvWeb.Markdown.render_post/2` drops every `<img>` at display time (so a
legacy inline reference in an old body, or a hotlinked remote picture, never
renders). The composer offers no "insert into text" action, and the Milkdown
editor strips image nodes client-side. The `VutuvWeb.PostComponents` card renders
`post.images` as the gallery/thumbnail row. Direct messages share the same rule
(`Vutuv.Chat.Message` + [messages.md](messages.md)).

All served versions are AVIF (see [images.md](images.md)), EXIF-autorotated and
**metadata-stripped** (no GPS leaks); the original keeps its metadata in the
private `originals/` tree and is never served.

Every image byte goes through the authorizing proxy `GET
/post_images/:token/:version` (`VutuvWeb.PostImageController`), so a post's
audience guards its images too — served with `send_file` everywhere (the
X-Accel-Redirect handoff was disabled after it failed in production).

Legacy `…/feed.webp` URLs in old post bodies keep resolving.
