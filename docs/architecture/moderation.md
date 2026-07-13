# Moderation (family-friendly by design)

Any member can report a post, a private message, a whole profile, a verified
organization page or a job posting (quiet "Report" affordances on every post
card, message bubble, profile footer, organization page and job posting;
categories: not family-friendly, bullying/harassment, spam, other — a job
posting instead offers *misleading job ad* / spam / other, gated per content
type in `Report.categories_for/1`).

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
back to the queue) only carries disputes, ignored cases, re-reports and profile
cases.

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

Every case carries an **audit log** (`moderation_events`: reports, freezes,
severances, owner self-service, escalations, rulings, strikes, `owner_removed`)
rendered as the History timeline on the admin case page, and the urgent admin
email names the profile, category and reporter's note instead of just a link.
