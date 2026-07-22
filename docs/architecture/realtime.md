# Real-time (LiveView)

vutuv adopts LiveView incrementally on top of classic controller + template
pages. This document covers the always-live app shell, the live pages, and
everything that updates without a reload.

## The app shell and live pages

The app shell `VutuvWeb.ShellLive` (sticky top bar + mobile bottom tab bar, with
live unread badges) is embedded in the shared `app` layout via `live_render`, so
the chrome and badges are live on every page.

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
[settings-and-account.md](settings-and-account.md)).

**Every state-changing control fires a LiveView event, so the page never
reloads**: the follow pill, the ⋯-menu mute/bookmark/like/block (and unblock),
the follower/following/who-to-follow follow buttons, and the tag-endorsement
pills. The follower/following/connection counts and
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
tables (followers, endorsements, connections — mutual follows —, replies, likes;
retroactively, no notifications table); each entry links to what it reports (the
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

The only stored state is the `users.notifications_read_at` read marker behind
the unread badge.

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
  itself still advances `users.notifications_read_at` and clears the bell.
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
what it is — this row does, and it opens `/settings/security`, where they can
change it.

It is derived like every other kind, straight from the member's own `users`
row: no notification table, no live push and, deliberately, **no email** — the
PIN mail just landed in their inbox, and this is an in-app note, not a second
message. `users.welcome_notified_at` is both the gate and the timestamp: it is
stamped once, by the same `Accounts.activate_user/1` branch that flips
`email_confirmed?` when the first login PIN is accepted, so the note appears
exactly at that moment. A NULL means no note, which is what every account
predating the feature keeps — the derived feed is otherwise retroactive, and a
welcome years after the fact would be nonsense.

## Live member counter

The logged-out landing page shows the **exact** number of members and ticks it
up in real time as people register. `Vutuv.Accounts.MemberCounter` keeps the
total in a lock-free `:atomics` cell (ref in `:persistent_term`), so the
per-render read (`count/0`) and the per-signup bump (`increment/0`, called from
`Accounts.register_user/2`) are O(1) and never hit the database — a signup spike
just races on one atomic add.

A single owner GenServer seeds the cell from the DB at boot, re-reads the
authoritative count on a slow timer (self-healing against deletions), and
broadcasts the value only when it changed, so a burst of signups coalesces into
at most one PubSub message per tick instead of a fan-out storm.

The pill is the embedded `VutuvWeb.MemberCountLive` (rendered via `live_render`,
like the shell).

The same broadcast drives a second, **admin-only** reader: the top bar's "new
members today" pill (`#new-members-today` in `ShellLive`), which shows how many
sign-ups confirmed since Berlin midnight and links into `/admin`. Only an admin
socket subscribes, so nobody else pays for it, and the pill is rendered only
above zero — a quiet day adds no chrome. Each `{:member_count, n}` message makes
it re-read `Vutuv.Dashboard.registrations_today/0` (the figure the admin
dashboard's "New members" tile shows) rather than adjusting a running tally, so
it cannot drift; `Vutuv.DayClock`'s midnight tick empties it out for the new
day.
