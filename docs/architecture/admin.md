# The admin panel

Admin rights are granted from the command line, never through a form (see
[Admin access](../DEVELOPERS.md#admin-access)). Some admin surfaces are
documented with their subsystem: the moderation queue in
[moderation.md](moderation.md), the deliverability dashboard in
[email.md](email.md), ad review in [ads.md](ads.md), the OAuth-app kill
switch in [api.md](api.md) and the legal-pages editor in
[ADMINS.md](../ADMINS.md).

## The panel and the live dashboard

The admin panel lives at `/admin`, reached from the **account menu** (an "Admin"
entry that only admins see; there is no other link to it).

At the very top sits a **live activity dashboard**
(`VutuvWeb.Admin.DashboardLive`, embedded like the shell): an at-a-glance pulse
of the system — how many members are online right now, plus today-vs-yesterday
post, direct-message and confirmed-sign-up counts and the time of the last post
and message.

The **Currently online** and **New members** cards also list the newest ten
members behind each figure (avatar + name, linking straight to the profile), so
an admin can look at who is online or who just joined without searching.

The "online now" figure and its list update the instant a member connects or
disconnects (via `VutuvWeb.Presence`); the rest refreshes on a gentle timer, so
it stays current without a reload.

Below it the panel groups the sections by what you come to do — **Moderation &
queues** (moderation, member browser, deliverability), **Communication**
(newsletters, audiences), **Content & taxonomy** (tags, usernames) and **System
& insights** (API apps, daily report, ads) — each tile with a one-line
description and, where it matters, a live count badge.

Every actionable admin page is a **LiveView** whose actions apply with no
reload: the member browser (`/admin/users`), the moderation queue + case page
(`/admin/moderation`, reload-free uphold/reject), the deliverability dashboard
(`/admin/deliverability`, thaw/clear) and the OAuth-app list (`/admin/api_apps`,
suspend/reactivate); the classic CSRF POST routes stay as the no-JS / scriptable
fallback.

A logged-in member without admin rights who opens `/admin` gets a 403 page that
explains exactly this: admin rights are granted by the instance operator
directly in the database (contact via Impressum).

## Member browser (`/admin/users`)

A **LiveView** list of **every account**, linked from the `/admin` panel, that
feels like a native app — **every change updates the page with no reload**.

The default view answers "who just joined?": **PIN-registered** members
(`email_confirmed?`), **newest first**.

**Search-as-you-type** by name, `@handle` **or email address** (debounced; the
email is matched server-side to find the account for support/moderation but is
never shown in the listing), filter by **registration** (PIN-confirmed / not
confirmed / all) and **account flag** (admins / identity-verified / awaiting
verification / frozen / suspended / deactivated / unreachable), and click a
column header (Member, Username, Joined) to sort either way.

The whole filter/sort state lives in the **URL** (`push_patch`), so a view is
shareable and the back button restores it.

Each row shows the registration plus moderation/deliverability state as badges,
and an inline **Verify** button that flips the row to "Verified" in place and
emails the member (`Vutuv.Accounts.verify_identity/1`, shared with the legacy
`POST /admin/users`) — so the old identity-verification queue is now just the
`?flag=unverified` view of this page (the `/admin` panel links straight to it
and badges its size).

Verification is **auto-revoked** if the member later edits any identity detail
the badge vouches for (any name part — first/middle/last name, nickname or
honorific title — plus gender or birthday): the admin's ID check was made
against exactly those details, so `User.changeset/2` clears `identity_verified?`
whenever one changes (the security chokepoint, so it bites on the edit form
**and** the `/api/2.0` `PATCH /me`), and the profile editor shows a friendly
toast explaining the badge was removed and why (to keep verified profiles
trustworthy and stop fake verified accounts). Re-verification is a fresh admin
action.

Live result count, paging (the `PageScroll` JS hook returns you to the top of
the list on each page change) and clear-filters round it out.

Query, filter and sort live in `Vutuv.Accounts.admin_user_filters/1` +
`list_admin_users/3` (offset-paginated via `Vutuv.Pages`, 50/page).

Admins-only via the `:admin` live_session (`on_mount :require_admin`).

## Member detail (`/admin/users/:id`)

Each browser row's name links to a **member detail** LiveView
(`VutuvWeb.Admin.UserDetailLive`) instead of straight to the public profile, so
an admin investigating a member lands on one screen carrying:

- the member's **account status** — the same registration + moderation/
  deliverability badges the browser row shows (shared with the browser through
  `VutuvWeb.Admin.MemberBadges`, so the two never drift);
- their **jobs footprint** (issue #934) — live and total postings, open
  job-related moderation cases, and the **cold-outreach counter** against the
  configured limit (amber once the member is at the cap), built by the same
  `Vutuv.Jobs.member_job_footprint/1` the `/admin/jobs` poster drawer uses;
- one-click links to the member's **preference overrides**
  (`/admin/users/:id/preferences`), **their postings** on the jobs board
  (`/admin/jobs?q=<handle>`) and their **public profile**.

Read-only and admins-only (same `:admin` live_session). A missing or malformed
`:id` redirects back to the browser rather than 500ing (the id is UUID-cast
before the DB lookup, like the sibling preferences page).

## Tags and honor tags (`/admin/tags`)

`/admin/tags` is the classic CRUD over the shared global tag catalog
(`Vutuv.Tags.Tag`: slug, name, description) — create, rename and delete the tags
members share. Deleting a tag removes it from every member who holds it
(cascading FK).

A tag can be flagged an **honor tag** (`tags.honor?`, edited on the tag's page).
That reserves the tag name site-wide as an **admin-granted badge** — think
`vutuv_developer` for the core team. The rules:

- **Members cannot self-assign it.** `Vutuv.Tags.add_user_tag/2` (the single
  self-assign chokepoint behind the tags editor, the JSON API, the LinkedIn
  import and account setup) refuses any name that resolves to an honor
  tag.
- **Members cannot self-remove it.** Self-removal goes through
  `Vutuv.Tags.delete_user_tag/1`, which refuses an honor user_tag
  (`{:error, :honor}`); the tags editor and the JSON API both inherit the
  guard.
- **Only admins grant/remove it.** The tag's `/admin/tags/:slug` page grows a
  **member roster** (`VutuvWeb.Admin.TagMemberController`): add a member by
  `@handle` or email, list the holders, remove one. Assignment runs through
  `Vutuv.Tags.admin_assign_tag/2` / `admin_unassign_tag/2`, which bypass the
  reservation deliberately (the route is admin-gated).
- **It is not endorsable** and renders with a small "honor tag" marker on the
  profile chip and in the `.md`/`.txt`/`.json`/`.xml` agent-doc siblings
  (`SectionDocs.tag_entry/1` carries `honor`).

Reserve honor for **fresh** names. Flipping an already-widely-held tag
locks its existing holders out of self-removal (there is no per-assignment
"granted by admin" record); the edit form warns about this.

## Organization pages (`/admin/organizations`)

`VutuvWeb.Admin.OrganizationLive` (issue #930) is the oversight dashboard for the
verified organization pages (`Vutuv.Organizations`, see `organizations.md`). Three overview
tiles (live / pending / frozen), a search over **name, alias and domain**, status
filter chips (all / live / pending / frozen / archived) and a paginated list. All
filter/status/page/selection state lives in the URL (`push_patch`), so a view is
shareable.

Opening an organization reveals a **detail drawer**: its domains with verification
state and `last_checked_at`, the team roles, the names/aliases (a flagged alias —
one matching another verified organization — carries an amber ⚑; see the collision
guardrail in `organizations.md`), the rename history (former aliases) and the
claiming member. The actions act reload-free:

- **Freeze / Unfreeze** — `Organizations.admin_set_frozen/2` sets/clears `frozen_at`,
  the exact effect of the report freeze (`moderation.md`): the page vanishes for
  the public but stays visible to its owner behind the owner banner.
- **Archive** — `archive_organization/1` sets status `archived`.
- **Delete** — `delete_organization/1`, only for a page with no job postings
  (`deletable?/1`; issue #932 adds the postings guard); otherwise archive.

A flagged-alias count surfaces both on this page and as the coral "attention"
badge on the `/admin` organization-pages card, and the operator's new-verified /
domain-dropped notices link here.

## Job postings (`/admin/jobs`)

`VutuvWeb.Admin.JobLive` (issue #934) is the oversight dashboard for job postings
(`Vutuv.Jobs`, see `jobs.md`), sharing the `OrganizationLive` scaffold. Four
overview tiles (live / expiring within 7 days / frozen / open job-related
moderation cases), a search over **title, poster (name / @handle) and
organization name**, status filter chips (all / live / expiring / frozen /
closed / expired / draft) and a separate **"⚑ Open reports"** toggle chip that
narrows to postings with an open moderation case. Filter/status/report/page/
selection state lives in the URL (`push_patch`), so a view is shareable. The
counts come from `Jobs.admin_overview_counts/0` (the open-case figure is
delegated to `Moderation.open_case_count("job_posting")`, so it can't drift), the
list from `Jobs.admin_jobs_page/1`.

Opening a posting reveals a **detail drawer** (`Jobs.admin_job_detail/1`): the
poster (linked), the employer attribution (a verified organization page vs a
free-text, unverified name), status, the view/apply counters, the published /
expiry dates, the **poster footprint** (live + total postings, open job-related
cases, and the cold-outreach counter — see below), and the **report history**
(every case for the posting, each linking to `/admin/moderation/:id`). The
actions act reload-free:

- **Freeze / Unfreeze** — `Jobs.admin_set_frozen/2` sets/clears `frozen_at`, the
  exact effect of a report freeze (`moderation.md`): the posting vanishes from the
  public board and every machine channel (sitemap, JSON-LD, agent formats — the
  `visible_to?`/`indexable?`/`agent_visible?` gates all key on `frozen_at`) but
  stays visible to its poster and admins. The freeze pings the public board topic,
  so an open `/jobs` re-queries with no reload. `jobs_freeze_compliance_test.exs`
  is the standing guard that a freeze really strips every channel.
- **Close** — `Jobs.admin_close/1` ends a live posting with the `:moderation` close
  reason (a regular ending, so the lifecycle stays honest), rather than deleting.
- **Delete** — `Jobs.delete_job_posting/1`, for clear abuse; purges the image files
  and settles any open case.

The **cold-outreach counter** is the anti-spam lever on pushy recruiting: `Vutuv.Chat`
caps how many new message *requests* one member may open to strangers (members who
don't already follow them) within a window (`COLD_OUTREACH_LIMIT` / `_WINDOW_HOURS`,
default 20 / 24h; see `ADMINS.md` and `messages.md`). A member over the cap gets a
friendly "try again later"; `Chat.cold_outreach_count/1` reads the current spend
(without moving it, via `RateLimiter.peek/2`) so admins see it in the drawer. Report
rulings on a job posting reuse the standard strike ladder (`moderation.md`), which
ends in account deactivation — the "freeze the HR account" lever.

An open-case count surfaces both on this page and as the coral "attention" badge on
the `/admin` job-postings card.

## Freeze an account (`/admin/accounts`)

A focused, admins-only **classic controller** page for putting any account into
the moderation freezer without waiting for a report (issue #812).

**Search** by name, `@handle` or email address (the same matcher as the member
browser), then hit **Freeze** (or **Unfreeze**) on a row. Freezing goes through
the public, audited `Vutuv.Moderation.admin_freeze_user/3` (not the private
`set_user_moderation!/2`): it sets `frozen_at` — which hides the profile and
everything it owns from everyone but the member and admins — and records a
caseless audit row in `moderation_admin_actions`. A freeze does **not** block
login (that is suspension/deactivation); a frozen member can still sign in and
sees their own amber banner. Freeze/unfreeze are **CSRF-protected POSTs** through
the `:browser` pipeline.

`/admin/accounts/frozen` is the paginated list of every currently-frozen account
(newest freeze first, `<.pager>`, 250/page) with a **Source** column (admin vs
report — an account frozen by an open report is labelled "report") and an
Unfreeze control. See `moderation.md` for the freeze machinery and the honest
403/410 HTTP status a withheld profile now returns (was a blanket 404).

Admins-only via the `:admin` pipeline (`Plugs.RequireLogin` + `Plugs.AuthAdmin`).

## Delete account (`/admin/users/delete`)

A focused, admins-only **LiveView** for permanently removing an account.

**Search-as-you-type** by name, `@handle` or email address (the same matcher as
the member browser), then hit **Delete** on a row to open an **"Are you sure?"
confirmation modal** naming the account.

Confirming runs the one `Vutuv.Accounts.admin_delete_user/1` chokepoint, which
snapshots the account's details (name, `@handle`, id, every email address and
phone number, post count, join date) **before** the cascade, then deletes the
account **and everything it owns** (posts, phone numbers, email addresses, tags,
endorsements, images, follows) via `delete_user/1`.

The deleted member is **never emailed**; instead the operator
(`sw@wintermeyer-consulting.de`) gets a record email
(`Emailer.account_deleted_notice/1`) listing what was removed and the **exact
deletion timestamp** (UTC + Europe/Berlin).

Admins-only via the `:admin` live_session (`on_mount :require_admin`).

## Email newsletter ("Rundbrief")

Admins compose a broadcast email at `/admin/newsletters`, save it as a
**draft**, send a **test** to any single address, then **broadcast** it to every
eligible member — and read the per-recipient **delivery log** (the protocol:
when which email went out, with status), which is **searchable** (recipient
email/@handle), **filterable** (kind: test/broadcast, status:
sent/suppressed/invalid/error), **sortable** by any column and **paginated**
(`Vutuv.Pages` + `<.pager>`, 50/page).

In the dev environment the newsletter pages link to the Swoosh mailbox at
`/sent_emails` (`dev_mailbox?/0`).

The body is **trusted Markdown** rendered to inline-styled HTML for clients
(`Vutuv.Newsletters.Markdown`, Earmark direct, no sanitizer so the styles
survive), with **merge variables** (`{{greeting}}` for a localized personal
salutation, plus
`{{first_name}}`/`{{last_name}}`/`{{name}}`/`{{username}}`/`{{email}}`)
substituted per recipient — HTML-escaped in the HTML body, raw in the text body
and subject.

Every message goes through the one `Emailer.newsletter_email/1` chokepoint (bulk
headers + RFC 8058 one-click unsubscribe).

It is **opt-out** (`users.newsletter_emails?`, default true, toggle on the
notification settings page or the unsubscribe link); the broadcast skips
unconfirmed, unreachable, suspended, deactivated and unsubscribed members, picks
each member's lowest-position deliverable address, and is **single-send**
(`draft → sending → sent`, an atomic lock stops a double click).

Sends run in the background (`Vutuv.TaskSupervisor`; inline in tests) and are
**crash-proof per recipient**: a malformed stored address (legacy imports left
addresses with spaces in them, which make the SMTP adapter's puny-encoding
raise) is trimmed, validated and logged as `invalid` instead of killing the
loop, and any per-recipient exception becomes an `error` row.

Each send is also **time-bounded** (`deliver_bounded/1`): it runs on a
supervised task the loop waits at most `NEWSLETTER_SEND_TIMEOUT_SECONDS` (60s
default) for, and a send that overruns is killed and logged `error`. This is
what keeps the auto-resume below honest — gen_smtp's `:timeout` option covers
only the socket connect, while each per-response read uses a hardcoded 20-minute
timeout, so without the bound a black-holing relay (socket open, no reply) could
freeze one send far past the 5-minute stuck window, so the broadcast looks dead
and gets a second run that double-mails the un-logged tail (#943). Bounding the
send keeps a delivery row landing well inside that window.

A broadcast whose task still dies mid-send (e.g. a blue/green deploy stopping
the slot) is **auto-resumed**: `Vutuv.Newsletters.BroadcastResumer` sweeps every
minute for newsletters stuck in `sending` with ≥5 minutes of no delivery
activity and finishes them, skipping recipients who already have a delivery row
(the staleness window plus a CAS lock on `updated_at` make the resume
double-send-safe across the deploy overlap).

Admins-only via the `/admin` pipeline.

Every vutuv.de link in the **HTML** body is **click-tracked**: its `href` (not
the visible URL) carries a signed per-recipient `?nlt=` token
(`VutuvWeb.NewsletterToken`), so when a recipient follows it the
`:browser`-pipeline plug `VutuvWeb.Plug.NewsletterClick` records who clicked
which link when (`newsletter_clicks`) and redirects to the clean URL; the
plain-text version keeps the bare link, and external links are left alone.

The newsletter show page then carries a **"Resonance" success overview**
(recipients, members who clicked + rate, total clicks, and a clicks-per-link
table, all over the broadcast audience) plus a paginated **click log** at
`/admin/newsletters/:id/clicks` (who clicked which link, when).

The Datenschutzerklärung describes the tracking (legitimate interest, opt-out
via the newsletter unsubscribe).

## Newsletter audiences / groups

Instead of always sending to everyone, an admin builds a **fixed audience** and
watches the matching-member count update **live** (a LiveView in its own
`:admin` `live_session`, guarded by the `:require_admin` on_mount).

The builder has two modes, chosen by a toggle at the top: **From filters** (the
default, below) and **Specific accounts** — a hand-picked allowlist (e.g. a
small group of testers) where the filters are hidden and the admin searches
members by `@handle` and adds them one by one; the audience is then **exactly**
those accounts.

(This relies on the audience query treating an empty filter as matching *nobody*
once any positive selector — a picked account or an added group — is present, so
a hand-picked list resolves to just those members rather than
everyone-plus-them; with no selector at all it still means everyone, which is
what the "all members" and "send to the rest" groups need.)

Filters: **language** (`locale`), **country** (the free-text `country` on
profile addresses, chosen from existing values), **age** (min/max from
`birthdate`, translated to `birthdate` bounds), **tag** (members holding a tag,
looked up by name) and **username** (an ILIKE handle pattern where `*`/`?` are
wildcards and a plain term is a contains-match).

An optional **cap** (`max_size`) takes N members for a test run — either the
**oldest first** (by join date) or a **random sample** of the pool
(`random_sample`) — and a group can **add** (`included_group_ids`, a union,
bypassing the filters) and/or **subtract** other groups (`excluded_group_ids`)
so "test run of 100, then the rest" partitions cleanly.

On top of the filters, individual accounts can be **hand-picked**: the paginated
preview/search list has a checkbox per member (tick to include, untick to
exclude), stored as `included_user_ids`/`excluded_user_ids` (exclusion wins); a
search-by-handle box finds any eligible member to add, **Select all / Unselect
all** apply to the whole current view (all matches, not just the page), and
excluded members show as undo-able "Removed" chips (capped, with a "+N more"
overflow so a bulk unselect can't render thousands).

The selection survives filter changes and paging.

The filter clauses combine as one Ecto `dynamic` so they can be OR-ed with the
added groups/accounts.

The name field comes **pre-filled** with a timestamped default (e.g. "Audience
2026-06-23 05:54", Berlin time), like the access-token form.

The builder shows a **live, paginated preview** of matching members (with links
to their profiles) so the admin can eyeball the filter, and each saved audience
has a **show page** (`:show`) listing its frozen members paginated, again as
profile links.

On save the matching members are **frozen into a snapshot**
(`newsletter_group_members`), so the subtraction is stable; the broadcast then
targets `group ∩ still-eligible` (a member who unsubscribed or bounced after the
snapshot is skipped).

The newsletter's broadcast card has an **audience picker** (all eligible
members, or a group) and records which group was used (`newsletters.group_id`).

## Daily activity report (`Vutuv.Reports`)

A basic operator metric for one German calendar day (Europe/Berlin via
`Vutuv.BerlinTime.day_bounds_utc/1`) — confirmed-by-PIN new registrations
(`email_confirmed?` accounts created that day) plus the day's posts, reposts,
likes and bookmarks, and the day's **email-deliverability** events (hard
bounces, address deactivations, account freezes and thaws, from
`Vutuv.Deliverability`).

Admins read it at `/admin/reports`, a time machine: `?date=YYYY-MM-DD`
(defaulting to yesterday) with prev/next links and a date picker.

`Vutuv.Reports.DailyReporter`, a supervised cron-style GenServer, schedules
itself for the next **00:05 Berlin** and mails the previous day's report to the
operator through the `Emailer` chokepoint (`daily_report_email/1`), **skipping
any day whose every metric is zero**.

The email **subject lists only the non-zero numbers** (e.g. "vutuv Tagesbericht
20.06.2026: 5 Registrierungen, 12 Beiträge, 1 eingefrorenes Konto"), so the
day's signal is readable at a glance.

Beyond the counts, every metric carries a capped **detail list**
(`DailyReport.detail_limit/0` = 25 rows, oldest first) so the report names *who*
and *what*: the new members (name, `@handle`, profile link), the created posts
(first line + permalink), the reposters / likers / bookmarkers, the new
Fediverse followers, the bounced / deactivated / frozen / thawed addresses and
the removed spam accounts. `VutuvWeb.ReportDetails.sections/1` normalizes the
sample into linked `%{primary, secondary, path}` lines that the email (HTML +
text) and the `/admin/reports` page all render, so the three surfaces stay in
sync; a busier day than the cap ends each section with a "… und N weitere" note.

Behind `config :vutuv, :daily_report_email` (off in tests, on by default).
