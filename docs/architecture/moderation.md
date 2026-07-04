# Moderation (family-friendly by design)

Any member can report a post, a private message or a whole profile (quiet
"Report" affordances on every post card, message bubble and profile footer;
categories: not family-friendly, bullying/harassment, spam, other).

A report from a reporter in good standing **freezes the content instantly**
(`frozen_at`) — it vanishes for everyone but the owner and admins, with no
public tombstone — and opens a `Vutuv.Moderation.Case`.

The owner is notified (in-app + email) and can settle it **without an admin** at
`/moderation/cases/:id`: delete it, edit it (auto-unfreezes; a re-report then
skips self-service) or dispute it ("my content is fine" — stays frozen,
escalates).

Silence for 72h escalates too (`Vutuv.Moderation.Sweeper`), so the admin queue
at `/admin/moderation` (a LiveView; the case page rules reload-free and drops
back to the queue) only carries disputes, ignored cases, re-reports and profile
cases.

Admin rulings are one click: **uphold** (owner gets a strike: warning → one-week
suspension → permanent deactivation; strikes expire after 12 months) or
**reject** (unfreezes; rejections lower the reporter's trust, and reports marked
*abusive* strike the **reporter** on the same ladder — reporting-as-a-weapon is
treated as bullying).

Reporters with a bad track record lose the instant freeze (their reports only
flag for review), whole profiles freeze only on a **second** independent trusted
report, and `/admin/moderation/reporters` shows every reporter's track record.

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

Every case carries an **audit log** (`moderation_events`: reports, freezes,
severances, owner self-service, escalations, rulings, strikes) rendered as the
History timeline on the admin case page, and the urgent admin email names the
profile, category and reporter's note instead of just a link.
