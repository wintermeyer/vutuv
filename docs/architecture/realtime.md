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

### CV updates (issue #980)

One notification kind is not about something that happened *to* the reader:
"@greta added a new position to their CV". A member who adds a new **CV** entry
— a work experience, an education entry or a certificate / license — can tell
the people who follow them, with one checkbox on the new-entry form (ticked by
default, hidden while they have no followers). Only those three sections
announce; the rest of the profile stays quiet.

**One notification per author per three hours, not one per entry.** Somebody
filling in five roles in one sitting is one piece of news, so the feed folds an
author's announced entries into fixed three-hour buckets
(`CvUpdates.bucket_seconds/0`) and renders one row that names them ("added 5 new
entries to their CV", each entry listed and linked, capped at five plus "and N
more"). The grouping is a plain `GROUP BY (author, bucket)` on the derived rows,
so the unread badge counts groups too and a burst can never inflate it. The
bucket window is baked into the SQL as a literal, not a query parameter: Postgres
compares a GROUP BY expression with the SELECT list syntactically, and two
placeholders are not the same expression.

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
the **whole group under its derived id** (the one exception to the "live-"
id namespace in `NotificationLive`), so a second entry within the window
updates that row in place instead of stacking another one.

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
