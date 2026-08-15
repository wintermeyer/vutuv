# Real-time (LiveView)

vutuv adopts LiveView incrementally on top of classic controller + template
pages. This document covers the always-live app shell, the live pages, and
everything that updates without a reload.

## The app shell and live pages

The app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with
live unread badges) is embedded in the shared `app` layout via `live_render`, so
the chrome and badges are live on every page.

### Installed on a phone (issue #1464)

The site is installable: `/site.webmanifest` (`VutuvWeb.PageController`)
declares it a `standalone` app named after `:node_name`, the same string the
fediverse directories print, so an operator answers "what is this installation
called" once. Its load-bearing key is **`scope: "/"`**. iOS decides from the
scope which links belong to the installed app and opens everything outside it
in a Safari overlay *on top of* the app — with no manifest at all that is what
a member got for ordinary navigation, which is what #1464 reported.

The document declares `viewport-fit=cover`, without which every
`env(safe-area-inset-*)` reads 0. That buys an app that paints edge to edge
and obliges the page to hand back the strips the device keeps: the tab bar
grows by the bottom inset and pads it away again (so its tabs keep their full
4rem), `<main>` and the footer reserve that grown height, the full-screen chat
subtracts it from its `100dvh`, the lightbox controls sit inside their inset,
and the content columns take `UI.gutter_class/0` — the page's 1rem gutter or
the sensor housing's inset, whichever is larger. Every one of those is exactly
the old value on a device that reports no inset, which is why the change is
invisible on a desktop. `mobile_tab_bar_css_test.exs` and
`web_app_manifest_test.exs` fail the build if a piece goes missing.

The **Messages** (`/messages`), **Notifications** (`/notifications`) and
**Search** (`/search`) pages are LiveViews under a `live_session`. The search
page itself is described in [search.md](search.md).

The **profile** (`/:slug`, `VutuvWeb.UserProfileLive`) is a LiveView too —
embedded by its controller via `live_render` (so the
`.md`/`.txt`/`.json`/`.xml`/`.vcf` agent siblings keep flowing through the
controller).

The **feed** (`/feed`, `VutuvWeb.PostLive.Feed`) is fronted the same way by
`VutuvWeb.NewsfeedController` so its own agent siblings can be negotiated (see
[agents-and-seo.md](agents-and-seo.md)), so it is the one LiveView no longer in
the `live_session`.

The **add-tag form** (`/settings/tags/new`, `VutuvWeb.TagNewLive`) is the first
live `/settings` page: it previews the parsed tags while the member types and
saves over the socket (see
[settings-and-account.md](settings-and-account.md)). The **Fediverse follower
browser** (`/settings/fediverse/followers`,
`VutuvWeb.FediverseFollowersLive`) is the other kind of live settings page: it
changes nothing, it *finds* something — search-as-you-type, a server filter,
sortable columns and paging over a follower list that can run to five figures,
with the whole view in the URL via `push_patch` (see
[fediverse.md](fediverse.md)). It and its mirror image, the **following
browser** (`/settings/fediverse/following`,
`VutuvWeb.FediverseFollowingLive`), are the settings pages that have to keep
themselves current: what they show is decided on other servers and reaches us
through the inbox, so an `Accept`, a `Reject`, a `Move`, an inbound `Follow` or
`Undo`, a rename, a prune or an instance block reloads the open page
(`:remote_follows_changed` / `:remote_followers_changed`) instead of waiting for
somebody to hit reload. A row that moved sweeps once through a brand tint
(`tr[data-row-changed]`), because a table that silently rewrites itself under
the reader looks like a misread.

**Every state-changing control fires a LiveView event, so the page never
reloads**: the follow pill, the header card's bookmark and like glyph toggles,
the ⋯-menu mute/block (and unblock), the follower/following/who-to-follow
follow buttons, and the tag-endorsement pills. The two save toggles raise no
flash: the glyph fills, which says it where the member is already looking. The follower/following/connection counts and
the tag-endorsement counts also update **live over PubSub even when the change
is made on another page or by another member** (e.g. someone follows you from
their feed); plain links (Message, Report, vCard, the agent-format links) stay
navigation, and the post action bars are their own embedded live views.

In-app updates flow over `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"`);
online status and typing use `VutuvWeb.Presence`.

A **site-wide online dot** (green badge on a member's avatar everywhere — lists,
profiles, post authors, the top bar) rides the same `VutuvWeb.Presence`: the
always-present shell tracks the current member online on one global topic and
pushes each viewer their own online-id set to a tiny JS hook that toggles the
dot on every `<.avatar presence>` in the page (classic controller pages
included). It is public **except across a block** (the shell filters each
viewer's set both ways) and each member can switch it off on the Privacy
settings page (`show_online_status?`), after which they are never tracked or
shown as online.

**Post timestamps** render server-side in Berlin time
(`VutuvWeb.UI.post_time/1`): a post from **today** shows just the time ("09:50
Uhr"), **yesterday's** the word plus the time ("Gestern, 09:50 Uhr"), older
posts the full date — and `Vutuv.DayClock` broadcasts at Berlin midnight so
every open feed / profile / notifications / likes page rolls its stamps over to
the new day with no reload.

The layout is split into `root.html.heex` (document shell) and `app.html.heex`
(chrome), shared by classic controller pages and LiveViews.

Notifications are real data **derived at read time** from the existing event
tables (followers, endorsements, connections — mutual follows —, replies,
mentions, likes; retroactively); each entry links to what it reports (the
post, the actor's profile), and a reply or like entry **quotes the post it is
about** so the feed is scannable at a glance: a like quotes the liked post, a
reply quotes **both** the member's own post and the reply itself (each truncated
to its first lines and linked to its own permalink, the reply respecting post
visibility so a restricted one never leaks).

A quote is **formatted the way `/feed` formats a post**, not shown as Markdown
source: it runs through `VutuvWeb.Markdown.render_preview/3` into the
`.markdown markdown--post` body recipe, so bold, lists, links, `@mentions` and
`#hashtags` read as themselves and headings flatten to bold. Because the body
then carries links of its own, the quote is a block with the permalink as a
**stretched link** underneath it rather than one big `<a>` (an `<a>` inside an
`<a>` is invalid) — the arrangement the feed's "Suggested posts" rail uses.
Inline image references are dropped before the quote is cut: the quote is text,
so a picture must not eat a line of the budget.

**How long a quote is, is the reader's own setting**: `:notification_post_lines`
(`Vutuv.Prefs`, shipped default 5 lines, an installation default an admin can
change at `/admin/preferences`, a member's own value on `/settings/preferences`).
It cuts the quote twice over — server-side to that many source lines (blank
lines between them kept, so the Markdown blocks still parse), so the rest of a
body never reaches the DOM, and visually through the `.notif-clamp` CSS clamp
fed by the inline `--notif-clamp` custom property (nothing inline while the
reader is on the shipped default, exactly like `.post-clamp`). The one-line
context excerpts (the "Your post:" breadcrumb above a reply, the handle-change
list) stay one line whatever the setting: they are index lines, not the quote.
They sit *inside* the row's own link, so they cannot carry links of their own —
`VutuvWeb.Markdown.to_plain_text/1` flattens their Markdown to plain text
instead, so no `**marker**` shows there either.

**Thread participation** is its own kind (`"thread"`): once a member writes in
a thread (they rooted it or replied in it), every later reply **anywhere** in
that thread notifies them too — not only direct answers to their own posts,
which stay the `"reply"` kind (an event is always exactly one of the two).
Answers from before the member joined the thread don't surface (they were on
screen when the member replied), own replies and blocked members never do.
The set "all replies of this thread" comes from `post_replies.root_post_id`,
the thread root denormalized onto every reply at creation (threading is
otherwise only a parent-pointer chain); a reply whose root was deleted carries
NULL there and stays out of thread events. Rows link to the new reply's
permalink and quote it; same-day events of one thread merge into one grouped
row. The write side (`Vutuv.Posts.create_reply/3` via `broadcast_reply/2`)
pushes the same event live to every participant's badge.

**Being named** is its own kind (`"mention"`): a post whose body says
`@handle` notifies that member, wherever the post sits. Before it existed a
mention reached you only by accident — if the post happened to answer one of
yours ("reply") or to land in a thread you had written in ("thread"); a mention
in a standalone post, or in a thread you are not part of, notified nobody.

This is the one feed kind that cannot be derived from current state cheaply: a
mention is plain text in `posts.body`, so deriving it would mean an ILIKE over
every post on every unread count — and that count runs on every page render for
the shell badge. So `Vutuv.Posts` resolves the body once at save time (through
`Vutuv.Mentions.mentioned_users/2`, the same grammar the renderer links with)
and **reconciles a `post_mentions` row per named member**; the feed reads that
table like any other source. Create, reply and every edit re-derive the set, so
adding a name notifies, removing one takes the event away again, and the body
stays the source of truth — the table is only a resolved index.

Left out at **write** time, because they belong to the post and are re-derived
on the edit that changes them: the author (naming yourself is not news) and
anyone the post is not visible to. Left out at **read** time, because they
change outside the post: a block either way (like thread events), and the
precedence rule below. Mentions of an **organization** handle notify nobody —
organizations share the handle namespace but have no feed.

**One post, one row.** The three post kinds are ordered `reply` > `mention` >
`thread`: an answer to your own post stays a "reply" even when it also names
you, and a mention supersedes the quieter "thread" event for the same reply. So
a single post never produces two notifications for the same reader.

`post_mentions` and `handle_change_notifications` are the two event tables
written for a feed kind rather than read from one that already existed.

### Read state: one marker plus per-post exceptions

Derived-feed-wise, read state is stored in exactly two places.

`users.notifications_read_at` is the **marker**: everything up to here has been
seen. `Activity.mark_notifications_read/1` bumps it when the member opens
/notifications, and anchors it to the newest *event* rather than the wall clock,
so an event landing in the same second is not swallowed (the event tables keep
second precision and the unread filter is a strict `>`).

`notification_post_reads` holds the **per-post exceptions**, written by
`Activity.mark_post_seen/2` when a member answers, likes, bookmarks or reposts a
post. Nobody does any of those four to a post they have not read, so whatever
the feed has to say about that post is news they already have — and the badge is
supposed to mean "things you have not looked at", not "things since your last
visit to /notifications". Before this, you could read an answer in the feed,
reply to it, and the badge would still insist on one unread notification until
you opened the page and dismissed it by hand.

The chokepoints are `Vutuv.Posts`'s `engage/4` (like / bookmark / repost, on the
idempotent repeat too), `do_create_reply/4` (the parent), and the feed's "Show N
new posts" pill: clicking it is the member choosing to look at exactly those
posts, so `PostLive.Feed`'s reveal marks the whole batch through the plural
`Activity.mark_posts_seen/2` (one recount broadcast for the batch, not one per
post). Marking broadcasts `:notifications_changed`, the shell's
recount-from-source signal, rather than decrementing a tally, so the badge
cannot drift.

Which events a seen post clears is `Activity.subject_post_id/1`, and it is
deliberately narrow — only the three kinds whose subject is somebody *else's*
post: the answer to your post ("reply"), the answer elsewhere in your thread
("thread") and the post that named you ("mention"). A "like" names your own
post, and bookmarking or reposting your own post says nothing about having seen
who liked it, so those keep waiting for a real visit. Only the **unread tally**
consults the table (`unread_notification_count/1`); `notifications_count/2` and
the feed itself do not, so the row stays listed and the pager's total is
unchanged — /notifications remains the log of what happened, it just stops
calling that row new. The page marks those rows with one extra query per page
(`Activity.seen_post_ids/2`), so the list and the badge tell one story.

### The notifications page (2026-07 redesign)

`VutuvWeb.NotificationLive.Index` renders the derived feed as **grouped rows
under Berlin-day sections** (`VutuvWeb.NotificationLive.Groups`, a pure
function over the item list). What reads as one piece of news merges into one
row, keyed within a Berlin calendar day: same-day likes of one post, the day's
new followers ("Anna, Ben and 111 more are now following you.", the overflow
linking to the member's followers list), the day's new connections, one
endorser's endorsements ("endorsed you for Elixir and Phoenix."), and same-day
thread events of one thread ("Anna and Ben replied in a thread you posted
in."). Direct replies and the rarer kinds (moderation, CV updates, handle
changes, ...) stay one row per event. Because grouping is pure, every change —
a page, a live push, the
DayClock midnight rollover — recomputes the sections wholesale; there is no
LiveView stream to patch, and a live-pushed like merges into the derived row
for its post/day.

Around the list:

* **Numbered pages** (`?page=`, the shared `<.pager>`), not an endless list:
  the page rides the URL beside the filter, so a page can be linked to, the
  back button works, and both are patched over the socket (`path=` makes the
  pager's links `patch` navigation). `Activity.notifications_page/2`'s `page:`
  option walks the merged feed by offset (`Vutuv.FeedPage.paginate_offset/3` —
  every source fetched from the top, so the cost grows with the depth) and
  `notifications_count/2` gives the pager its total **under the same filter**.
  A `?page=` past the end falls back to page 1, like every browse page. The
  endless "Load more" cursor stays the newsfeed's and the API's way of walking
  the same sources.
* **Live events only reach page 1.** An older page is a fixed window into the
  past, so a pushed event that arrives while the reader is on page 3 only
  bumps the pager's total; page 1 merges it into its group as before and drops
  its own overflow item so the page stays one page long.

* **Unread highlighting**: events newer than the previous visit's read marker
  get a tint + coral dot and a "N new notifications" header line; the visit
  itself still advances `users.notifications_read_at` and clears the bell. A row
  whose post the reader already engaged with is exempt (see the read-state
  section above) — it is listed, plain.
* **Filter tabs** (all / posts / people / more) restrict the feed server-side
  via `Activity.notifications_page/2`'s `kinds:` option (only the matching
  source queries run, so pagination stays exact) and live in the URL
  (`?filter=`), patched without a reload.
* **The rail** (right column on md+, below the list on phones), loaded on the
  connected mount only: **Follow back** — `Social.followers_to_follow_back/2`,
  recent followers not yet followed back, followed reload-free via the shared
  `<.user_row live?>` — and **Last 30 days**, a per-kind count card from
  `Activity.activity_summary/2` (one round trip of scalar subqueries).

Row times are the Berlin wall clock (the site's canonical clock, like post
stamps), server-rendered final with an ISO-8601 UTC `datetime` for machines.

### CV updates (issue #980)

One notification kind is not about something that happened *to* the reader:
"@greta added a new position to their CV". A member who adds a new **CV** entry
— a work experience, an education entry or a certificate / license — can tell
the people who follow them, with one checkbox on the new-entry form (ticked by
default, hidden while they have no followers). Only those three sections
announce; the rest of the profile stays quiet.

**One notification per sitting, not one per entry.** Somebody filling in five
roles in one go is one piece of news, so the feed folds an author's announced
entries into *sittings* and renders one row that names them ("added 5 new
entries to their CV", each entry listed and linked, capped at five plus "and N
more"). A sitting is a **gap-and-islands** group: entries less than
`CvUpdates.gap_seconds/0` (three hours) apart belong together, and a longer
quiet stretch starts a new one. Deliberately not a fixed three-hour raster —
that would split 08:59 and 09:01 into two notifications while merging 09:01 and
11:59 into one. In SQL it is `lag()` over the author's entries → a
"starts a new sitting" flag → a running `sum()` → `GROUP BY (author, sitting)`,
all over the derived rows, so the unread badge counts sittings too and a burst
can never inflate it. The gap is baked into the SQL as a literal, not a query
parameter: a window expression repeated in an outer GROUP BY is matched
syntactically by Postgres, and two placeholders are not the same expression.

It is derived like every other kind, from the CV rows themselves
(`Vutuv.Profiles.CvUpdates.feed_query/1` is the single rule behind the items,
the count and the read marker): so deleting the entry removes it from its group,
renaming the job renames it, and nothing is duplicated into a notifications
table. Who is told: everyone who followed the author **before** the entry
appeared (no backfill for a new follower), minus muted follows, minus readers
who switched the kind off.

Two flags carry it, one per side:

* `announce_to_followers?` on `work_experiences` / `educations` /
  `qualifications` is the **author's** choice, cast **only on insert**
  (`Vutuv.Profiles.CvSection.cast_announcement/2`), so editing an old entry can
  never fire a second round and the LinkedIn import — which never sets it —
  stays silent.
* `users.cv_update_notifications?` is the **reader's** opt-out (default on), the
  one in-app kind that is switchable, on the notification settings page.

It never sends email. `CvUpdates.announce/2` (called from the three create
actions and the API create) only adds the live push to the same set of
followers, so an open session's bell lights up at save time. The push carries
the **whole sitting under its derived id** — author plus the sitting's *start*,
the part that does not move as it grows (the one exception to the "live-" id
namespace in `NotificationLive`) — so a second entry updates that row in place
instead of stacking another one.

### The username welcome note

The very first thing a confirmed account finds in its feed is not about someone
else: **"Ihr vutuv-Username ist @egon_mueller."** vutuv *generates* the handle
from the member's name (`Vutuv.Handles`), so nothing in sign-up ever told them
what it is — this row does. Its links sit inside the sentence rather than
wrapping the whole row: the handle goes to the member's own profile,
`/settings/username` changes it, and `/settings/import/linkedin` rides along
because this is the one moment somebody arriving from LinkedIn still has that
profile in mind.

It is derived like every other kind, straight from the member's own `users`
row: no notification table, no live push and, deliberately, **no email** — the
PIN mail just landed in their inbox, and this is an in-app note, not a second
message. `users.welcome_notified_at` is both the gate and the timestamp: it is
stamped once, by the same `Accounts.activate_user/1` branch that flips
`email_confirmed?` when the first login PIN is accepted, so the note appears
exactly at that moment. A NULL means no note, which is what every account
predating the feature keeps — the derived feed is otherwise retroactive, and a
welcome years after the fact would be nonsense.

## The dead-render → socket-mount handoff (profile + feed)

Every LiveView visit computes its data twice: once for the HTML the visitor
sees immediately (the dead render) and once when the websocket connects and
`mount/3` runs again in a fresh process — identical data, seconds apart,
~50 queries each on the profile. **`VutuvWeb.Live.MountHandoff`** (an ETS
table + sweeper in the supervision tree) lets the dead render pass its
finished work to the connected mount: the dead mount stashes the assigns it
computed under `{authenticated viewer id, subject}`, the connected mount
takes (consumes) them and skips the reload. `UserProfileLive` stashes the
assigns `load_profile/1` added (diffed, not listed, so new assigns ride
automatically) and recomputes only the two connected-only slices (social-feed
ETS reads, code-stats refresh request); `PostLive.Feed` stashes its
`feed_payload/1` map and rebuilds the stream from it (a consumed
`LiveStream` struct must never ride a handoff — it would replay empty).

It is deliberately **not a cache**: single-use (`:ets.take/2`, so a
reconnect after a blip or deploy full-loads), keyed by the *server-side*
authenticated viewer on both ends (never by anything the client sent;
anonymous visitors — mostly crawlers whose socket never connects — are never
stashed for), expired after ~15s, and fail-closed (any miss runs the normal
full load). The accepted trade: changes landing in the sub-second gap
between the two renders are not re-read at connect; both pages subscribe to
their PubSub topics at connect, so the next event heals the snapshot.
Regression tests in `user_profile_perf_test.exs` and
`post_feed_live_test.exs` pin both sides: a hit connects on a handful of
queries, a consumed stash still full-loads.

## Live people counter

The middle of the top bar shows, on every page, the **exact** number of people
around this installation and ticks it up in real time. That figure is two
populations added up, because a reader asking how big this place is does not
care which side of the fence somebody stands on:

* the confirmed **members** here (`Vutuv.Accounts.count_users/0`), and
* the distinct remote **accounts** that follow a member, a page or a topic of
  this installation from the Fediverse
  (`Vutuv.Fediverse.distinct_follower_count/0`).

**Nobody is counted twice.** `fediverse_followers` holds one row per (actor,
followed thing), so one Mastodon account subscribed to two members and three
tags owns five rows and is one person — hence a `count(distinct actor_uri)`
rather than a row count (the row figure is what `Fediverse.stats/0` reports to
the admin dashboard as `remote_followers`, and it stays that). Actors on our
own hosts (the site, its `www.` alias, the tag host) are left out: such a
person is already in the member half. What the count cannot see is one human
running two Mastodon accounts, or a member who also follows us from elsewhere —
those are two accounts, and two is what it says.

`Vutuv.PeopleCounter` keeps both halves in a lock-free `:atomics` cell (slot 1
members, slot 2 Fediverse accounts, ref in `:persistent_term`), so the
per-render read (`counts/0`) and the two member writes are O(1) and never hit
the database — a signup spike just races on one atomic add.

Both member writes are conditional on the account being one the advertised
total counts, i.e. a **confirmed** one (`Accounts.count_users/0` counts by
`account_confirmed_row/1`):

* `increment/0` is called from `Accounts.activate_user/1`, on a genuine first
  confirmation (`email_confirmed?` false → true), **not** at registration — an
  unconfirmed sign-up is not a member yet (issue #781).
* `decrement/0` is called from `Accounts.delete_user/1`, the deletion
  chokepoint, so a departure shows up at once instead of waiting for the next
  reconcile. The same function deletes abandoned sign-ups, which were never
  counted, so it only ticks down for an account that was confirmed (a legacy
  `nil`-activated one counts as confirmed). The cell is unsigned, so a
  subtraction that would cross zero — only reachable in the sub-second before
  the first reconcile seeds it — is clamped instead of wrapping to 2^64-1.

The two halves move in deliberately different ways. A sign-up or a deletion
happens in this application, so it ticks the member slot at once. A remote
Follow arrives in the inbox, where the interesting question is not "one more"
but "is this account already counted somewhere else" — a question only the
database can answer. Rather than teach eight write paths (three add, three
remove, the pruner, an instance block) to ask it and risk one of them
forgetting, the owner process re-reads the whole head count **once a minute**.
So a new Fediverse follower shows up within a minute rather than instantly, and
there is exactly one place that decides what the figure means. The read is a
single aggregate over `fediverse_followers`, served by that table's
`actor_uri` index.

A single owner GenServer seeds both slots from the DB at boot, re-reads the
authoritative member count on a slow timer (self-healing against any
out-of-band change) and the Fediverse head count on the one-minute timer, and
broadcasts `{:people_count, %{members:, fediverse:, total:}}` only when the
figures changed, so a burst coalesces into at most one PubSub message per tick
instead of a fan-out storm.

Two readers consume that broadcast:

The top bar's people total (`#people-total` in `ShellLive`) is on every page.
**Every** socket subscribes — logged in or not, since the total is public — and
takes the new figures straight from the message. It is `delimited_count/1`, the
exact grouped figure, never a compacted "60K": a rounded total would never
visibly move, and moving is the point. The visible word beside it is
"people"/"Personen".

**The breakdown rides the `title`, the plain total rides the `aria-label`**,
and that split is deliberate. Hovering asks "what is this number made of", and
the answer does not need to repeat the figure the cursor is on, so the title is
"5,508 vutuv members plus 412 Fediverse accounts that follow them" (the plural
follows the *Fediverse* half — that is the number that is genuinely 1 on a
young installation). An `aria-label`, though, **replaces** the element's own
text for a screen reader, so it stays the plain "5,950 people": the visible
label has to be inside the accessible name (WCAG 2.5.3), and the breakdown
would push the figure out of it. An installation nobody follows from out there
gets the plain total in both. Zero renders nothing (the window before the first
reconcile), and the slot around it is always rendered so the bar keeps its
shape either way. The pill links to the public member directory at
`/system/members`, which deliberately does **not** repeat the breakdown — that
page prints the count it lists and nothing else (see
[agents-and-seo.md](agents-and-seo.md)).

The second reader is **admin-only**: the top bar's "new members today" pill
(`#new-members-today` in `ShellLive`), which shows how many sign-ups confirmed
since Berlin midnight and links into `/admin`. Only an admin socket runs its
query (every socket receives the messages, but the `recount` is gated on
`user_admin?`), and only when the **member** half is what moved — a Fediverse
follower arriving says nothing about today's registrations. The pill is
rendered only above zero, so a quiet day adds no chrome. Each such message
makes an admin socket re-read `Vutuv.Dashboard.registrations_today/0` (the
figure the admin dashboard's "New members" tile shows) rather than adjusting a
running tally, so it cannot drift; `Vutuv.DayClock`'s midnight tick empties it
out for the new day.
