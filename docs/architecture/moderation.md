# Moderation (family-friendly by design)

Any member can report a post, a private message, a whole profile, a profile
picture or cover, a verified organization page or a job posting (quiet "Report"
affordances on every post card, message bubble, profile footer, organization
page and job posting;
categories: not family-friendly, bullying/harassment, spam, **copyright**, other
— a job posting instead offers *misleading job ad* / spam / copyright / other,
gated per content type in `Report.categories_for/1`).

The same freeze → case → strike machinery covers every content type; `frozen_at`
lives on the reported row and its context's visibility chokepoint reads it. For
a **job posting** a report in good standing freezes it off the public board and
every machine channel (issue #932/#934), and the oversight lives at `/admin/jobs`
(see `admin.md` + `jobs.md`) alongside the shared `/admin/moderation` queue —
a job-posting case shows a "Job posting" label and links straight to the posting.

A report from a reporter in good standing **freezes the content instantly**
(`frozen_at`) — it vanishes for everyone but the owner and admins, with no
public tombstone — and opens a `Vutuv.Moderation.Case`.

The owner is notified (in-app + email) and can settle it **without an admin** at
`/moderation/cases/:id`: delete it, edit it (auto-unfreezes; a re-report then
skips self-service) or dispute it ("my content is fine" — stays frozen,
escalates).

Silence for 72h escalates too (`Vutuv.Moderation.Sweeper`), so the admin queue
at `/admin/moderation` (a LiveView; the case page rules reload-free and drops
back to the queue) only carries disputes, ignored cases, re-reports, profile
cases — and every open copyright case (see below).

## The copyright notice (issue #2008)

"Uses a text, photo or video without the rights holder's permission" is offered
on every report form **except** the private-message one — nothing was published
there, so there is nothing for a rights holder to have taken down. It is the one
category that is a *legal* notice rather than a house-rule complaint, and three
things follow from that.

**It is only accepted complete.** `Report.changeset/3` requires the note (which
work, where the original can be seen) and a good-faith declaration whenever the
category is `copyright`. The declaration is a **virtual** field, not a column:
the changeset refuses the category without it, so a stored copyright report *is*
the record that it was made, and a column would be a second copy free to drift.
The check sits in the changeset rather than in the controller, so the Mastodon
report API cannot file half a notice either (it has no field for the
declaration, so it cannot file one at all — a client sending that category gets
a 422).

**It is in the admin queue from the moment it is filed.** The trust ladder is
untouched — a trusted reporter still freezes the content and still leaves the
owner their 72h self-service window, an untrusted one still only flags — but
`Moderation.list_queue/0` and `open_queue_count/0` also take an open case with
a copyright report in any status, `pending_owner` included, via an `EXISTS`
on the reports (`queue_query/0`).

**An edit no longer settles it.** For every other category the owner's edit
unfreezes the content and closes the case; for a copyright case
`Moderation.content_edited/1` keeps the freeze, logs the edit and escalates, so
a human decides whether the revision removed the work. Delete and dispute are
unchanged. The case page and the owner's email both say so, because both read
`Moderation.owner_notice/1` (see below).

Admin rulings are one click: **uphold** (owner gets a strike: warning → one-week
suspension → permanent deactivation; strikes expire after 12 months) or
**reject** (unfreezes; rejections lower the reporter's trust, and reports marked
*abusive* strike the **reporter** on the same ladder — reporting-as-a-weapon is
treated as bullying).

For a clear-cut spam or abuse account the case page also offers a decisive
**remove** ruling (`Vutuv.Moderation.remove_owner/4`) that skips the warn-first
ladder: **deactivate** stamps an internal `users.moderation_reason` (`"spam"`),
hides the account site-wide and is **reversible** (`Accounts.admin_restore_user/1`,
the green "Restore" button in the member browser), or **delete** erases the
account outright through `Accounts.admin_delete_user/1` (the operator gets the
usual delete record email; the case is erased with it). The member browser
`/admin/users` has a **"Removed as spam"** filter, spam-removed rows carry a
**Spam** badge, and the nightly operator report counts the day's spam
deactivations ("Als Spam entfernte Konten"). The mark is internal only — never
shown publicly.

Reporters with a bad track record lose the instant freeze (their reports only
flag for review), whole profiles freeze only on a **second** independent trusted
report, and `/admin/moderation/reporters` shows every reporter's track record.

**Spam auto-defense:** distinct **spam-category** reports also freeze a whole
profile pending admin review once enough pile up (`@spam_freeze_reporters`, 5),
**even from untrusted reporters** — so a bot blasting the network is hidden in
minutes instead of waiting on an admin. The bar is kept higher than the two
trusted reporters so a small collusion ring cannot cheaply hide a rival; the
freeze is reversible (a rejected case restores everything and can mark the
brigaders' reports abusive).

Suspended/deactivated accounts cannot log in and disappear from feeds, profiles
and search.

House rules live at `/community`.

**Reporting someone also separates the two accounts on the spot** (before any
second report or admin ruling): connection and follows are removed and the 1:1
conversation is frozen for both sides; the report form warns a tied reporter up
front (including that the separation de-facto reveals who reported), and after
sending the reporter is told again (flash + a notification) that the pause works
in both directions and is undone if admins find the report unfounded - a
rejected case restores exactly what was cut (recorded in
`moderation_severances`), an upheld one leaves the separation in place.

Profile and message reports also capture a **full-page evidence screenshot** at
report time (`Vutuv.Moderation.EvidenceScreenshot`: headless Chromium with a
very tall window, trimmed by libvips; message threads render through the
token-guarded `/moderation/evidence/:token` page), stored under the private
`moderation_evidence/` tree and shown to admins via the authorizing
`/admin/moderation/:id/evidence` route.

**A takedown also leaves the building** (issue #1102). Freezing a post revokes
the copies on other Fediverse servers (`Vutuv.Fediverse.revoke_post/1`) and
lifting the freeze publishes it again, so a freeze is not a local fiction while
the post stays up on Mastodon; a **permanent** account removal — `remove_owner/4`
with `:deactivate`, and the strike ladder's third strike — broadcasts the actor
`Delete` the way a real account deletion does. Everything temporary deliberately
sends nothing: a week's suspension or a profile freeze must never tell the
network an account is gone, and one report must not fan a `Delete` out over every
post a member ever published. The reasoning, the addressing and the limits are in
`fediverse.md`; remote deletion is advisory by protocol, so this asks, it does not
promise.

Every case carries an **audit log** (`moderation_events`: reports, freezes,
severances, owner self-service, escalations, rulings, strikes, `owner_removed`)
rendered as the History timeline on the admin case page, and the urgent admin
email names the profile, category and reporter's note instead of just a link.

## A picture is reportable on its own (issue #2012)

A stolen profile picture used to be reportable only as the whole profile, which
a single report never hides — and even a frozen profile kept its pictures
online, because nginx serves those files straight off disk. `image` is the
report type for the picture itself: `fetch_content/2` resolves it through
`Vutuv.Images.Image`, the `images` row #2013 gave every profile picture and
cover, and the ⋯ menu on a profile offers "Report the profile picture" beside
the profile's own Report whenever that picture has a row.

**Its freeze is a file move, not a column write.** `Vutuv.Images.freeze/1`
stamps `frozen_at`, clears the member row's four columns for that kind, and
moves every derived version, the private original and anything still in AI
quarantine into the picture's **takedown hold** — see the hold section in
[images.md](images.md) for what that tree is and why an interrupted move is
finished by itself. Clearing the columns is the half a reader notices: the
member row is still what every URL builder and every display gate reads (#2027
moves them onto the row), and "no picture of that kind" is the one answer all
of them already agree on, so the profile, the cards, the vCard, the
link-preview JPEG and the ActivityPub icon all fall back at once. Nothing is
lost by clearing them — the row holds the same four values and the unfreeze
writes them back.

**Rejecting the case restores the picture byte for byte**, at the same paths,
so the old URL works again; **upholding it deletes** the held copies and the
private original, which is the one content type an admin ruling removes (a
post stays frozen as evidence). The owner's self-service is **remove or
dispute** — there is no edit, because a picture cannot be revised. `image`
reports offer *not family-friendly*, *bullying*, **copyright** and *other*;
spam is deliberately left out, because an advert as a profile picture is a
complaint about the account and belongs on the profile, where the spam
auto-defense counts it.

**While a picture is held it cannot be replaced.** `put_profile_image/3`
refuses the upsert and the profile form says why, because one row per member
per kind means a replacement would move the open case onto bytes nobody
reported. `frozen_at` is deliberately **not** in that upsert's replace list for
the same reason.

**The reported picture is only visible on the case pages.** `GET
/moderation/cases/:id/image` authorizes owner-or-admin and streams the held
copy (or the still-served one, when an untrusted reporter only flagged the
picture); both the owner's case page and the admin's render it from that one
route. Without it an admin could not see what a copyright claim is about.

## The statement of reasons (issue #2010)

A member whose content goes dark is owed more than "something of yours was
reported". Three surfaces carry the same five facts — the category, the
reporter's explanation **quoted** (never who wrote it), that the hiding was
**automatic** rather than a person's decision, the ground (the house rules, or
the law), and the options that case really has, with the 72-hour deadline where
there is one. This is what the Digital Services Act calls a statement of reasons
(Art. 17); the member-facing text never says so.

`Moderation.owner_notice/1` is the one place all three read: it returns the
deduplicated `categories` (most recent report first), the `category` to name
where there is room for only one, the reporters' `notes`, and `copyright?`.
The reporter is deliberately not in the map — a surface cannot leak what it
was never handed. The three surfaces are

- the case page `/moderation/cases/:id`, which the controller hands the notice
  as `@notice`;
- the owner's email (`moderation_frozen_*` and `moderation_review_*`, three
  locales × two formats), built by `Emailer.statement_of_reasons/2`;
- the in-app line, which names the category and the automatic freeze and links
  to the case page (`NotificationLine.notification_text/1`; the category is
  read back per page by `Moderation.notice_category_by_case/1`, one query, not
  one per row — and only for a case that is still hidden, since a settled one's
  line names the ruling). The **digest mail** delegates this one kind to that
  same function, so a member who reads the mail instead of opening the app is
  told the same thing.

Two things the mail must not get wrong. **The options are the options that case
actually has**, and `Moderation.owner_edit_offer/2` answers that as one value
(`:immediate` / `:reviewed` / `:none`) rather than as two booleans each of the
seven rendering places recombines: only a post has an editor behind the case
page's button, so a reported message or job posting gets delete and dispute,
and a **copyright** case is never promised that an edit makes the content
visible again — an admin looks at the revision first. (`owner_edit_offer/1` is
the same answer for the email, which does not already hold the content and
reads the database only when the type could have an editor at all.) And the
**review** mail (an escalated case: a re-report after a self-service round, or
a frozen profile) promises no 72-hour window and no self-service, because there
is none.

The reporter's note is a stranger's text shown to the accused member. The HTML
half renders it through `EmailComponents.email_quote/1`, which escapes it and
does **not** turn it into Markdown or links — a clickable link out of an
accusation is a phishing seat. The `text/plain` half has no escaping at all, so
`UserHelpers.email_quoted_text/1` wraps it at 72 characters and prefixes every
line with `"> "`: without that, a crafted note can be shaped to read as our own
signature followed by a second, fake link. **Both halves decide where a line
ends in one place** (`UserHelpers.split_lines/1`, PCRE's `\R` with the `u`
modifier), because a break the reader's client honours but our split does not
puts the rest of the note outside the marker — see `email.md` for why the rule
is written as the effect rather than as a list of `\r\n`, `\r` and `\n`.

## Admin-initiated freeze (`/admin/accounts`, issue #812)

Freezing an account no longer only happens reactively as a report side effect.
The **admin account tool** at `/admin/accounts` (see `admin.md`) lets an admin
search any account (by name, `@handle` or email) and freeze / unfreeze it
directly, with a paginated moderation-freezer list at `/admin/accounts/frozen`.
The public, audited entry points are `Moderation.admin_freeze_user/3` and
`admin_unfreeze_user/2` (never the private `set_user_moderation!/2`): they set /
clear `frozen_at` and record a **caseless** audit row in `moderation_admin_actions`
(`Vutuv.Moderation.AdminAction`, mirroring the deliverability ledger — an
immutable, FK-free record of who froze whom, when, and an optional reason). A
freeze sets `frozen_at` only, so it hides the profile everywhere but does **not**
block login (that is what suspension/deactivation do). The frozen list derives
each row's **Source** (admin vs report) from `report_frozen_ids/1`: an account
with an open user `Case` was frozen by a report, everything else by an admin. An
admin thaw clears `frozen_at` even for a report-frozen account (a deliberate
override); the case stays in the queue and its later ruling clears an
already-nil `frozen_at` as a no-op.

## The HTTP status of a withheld profile (issue #812)

`VutuvWeb.Plug.EnsureActivated` no longer returns a blanket 404 for every hidden
profile — a 404 ("does not exist") lied about an account that exists and is
merely withheld. `Moderation.withheld_status/1` classifies the reason once
`profile_visible_to?/2` has said no:

- a **never-activated** registration keeps **404** — it must stay
  indistinguishable from a non-existent account (anti-enumeration), and that
  wins first even when the row is also frozen;
- a **reversible hold** (frozen / suspended / unreachable) returns **403
  Forbidden** — the account exists and is withheld;
- a **permanently deactivated** account returns **410 Gone**.

The owner/admin HTML bypass (200) is unchanged, and HTML and the agent-format
siblings (`.md`/`.json`/`.xml`/`.vcf`) share the plug, so they always report the
same status. 403/410 render a profile-specific "This profile is currently
unavailable" page (`VutuvWeb.ErrorHTML`, `profile_unavailable.html`) that does
not reveal *why*. The separate `/api/2.0` JSON API keeps its own 404 for hidden
accounts — it is not an agent-format sibling and follows problem+json
conventions.

## The public-visibility gate, and the index behind it

"Is this member publicly visible" is one predicate, spelled once in
`Vutuv.Moderation.Query`: `account_confirmed_row(u) and not
account_hidden_row(u)`. Roughly 55 query sites across 13 modules filter on it —
search, the follower / following / connection lists, the tag pages, the member
directory, the fediverse actor — so it is the single most-evaluated condition
in the app.

It comes in two spellings, and picking the wrong one is a performance bug:

- **`account_hidden_row(u)`** takes an already-joined users row and reads its
  columns. **Use this whenever the users row is in scope** (a join or the main
  binding), which is nearly always.
- **`account_hidden(user_id)`** is a correlated `EXISTS` against the users PK,
  for the case where the users row is *not* joined — `Vutuv.Posts` scoping a
  post by its author is the real example. It costs one subquery per candidate
  row, and because it sits outside the row's own predicate it also splits the
  gate in two, which stops the index below from applying.

The index is `users_visible_index`: a partial index on `users (id)` whose
predicate is the static half of the gate (confirmed, not frozen, not
deactivated, not unreachable). It exists because the gate is far more selective
than the table size suggests — on the production data only ~9% of members pass
it, the rest being legacy accounts that never confirmed their email — so
without it every gated query read the whole `users` heap to find a small set.

Two things to know when touching this:

- The `suspended_until > now()` arm is deliberately **not** in the index
  predicate: `now()` is not immutable, so Postgres rejects it there. It stays a
  filter on the rows the index returns. The implication still holds, because
  the query's WHERE is the index predicate *and* the suspension test, which only
  narrows it.
- Postgres uses a partial index only when it can **prove** the query predicate
  implies the index predicate, and it fails silently — a gate that drifts from
  the index just goes back to full scans, with nothing in the logs.
  `test/vutuv/moderation/visibility_index_test.exs` is the tripwire: it plans a
  query built from the two macros with sequential scans disabled and fails if
  the index no longer serves it. Change the gate and that test tells you to ship
  a migration recreating the index.
