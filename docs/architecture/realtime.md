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

The only stored state is the `users.notifications_read_at` read marker behind
the unread badge.

### The notifications page (2026-07 redesign)

`VutuvWeb.NotificationLive.Index` renders the derived feed as **grouped rows
under Berlin-day sections** (`VutuvWeb.NotificationLive.Groups`, a pure
function over the item list). What reads as one piece of news merges into one
row, keyed within a Berlin calendar day: same-day likes of one post, the day's
new followers ("Anna, Ben and 111 more are now following you.", the overflow
linking to the member's followers list), the day's new connections, and one
endorser's endorsements ("endorsed you for Elixir and Phoenix."). Replies and
the rarer kinds (moderation, CV updates, handle changes, ...) stay one row per
event. Because grouping is pure, every change — load more, a live push, the
DayClock midnight rollover — recomputes the sections wholesale; there is no
LiveView stream to patch, and a live-pushed like merges into the derived row
for its post/day.

Around the list:

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
