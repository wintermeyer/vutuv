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
`post_replies` row naming the parent (`Vutuv.Posts.create_reply/3`) **and the
thread root** (`root_post_id`, denormalized at creation — threading is
otherwise only a parent-pointer chain — so "all replies of this thread" is one
indexed lookup; it feeds the thread-participation notifications, see
[realtime.md](realtime.md)). The root reference nilifies when the root post is
deleted.

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

## Link screenshots

A post that carries **exactly one URL and no image attachment** gets an
auto-generated screenshot of the linked page, captured off the request path so
the save is never slowed. The subsystem is `Vutuv.Posts.Screenshots` with the
`post_screenshots` table (one row per post, unique `post_id`), which is **both
the durable queue and the attachment record**: a `pending`/`capturing`/`failed`
row is work, a `ready` row carries the stored screenshot.

Two kinds of link are deliberately **not** screenshotted. A link to *this*
installation's own **`/settings`, `/admin` or `/system`** area is rejected in
`qualifying_url/1` (a pure, no-network check on the request path, so no row is
ever created) — the host is derived from `VutuvWeb.Endpoint.host()`, never a
literal `vutuv.de`, so it holds on any installation, and a shot of those pages
would only ever be a login redirect or an internal page.

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
