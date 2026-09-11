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
category is `copyright`. The check sits in the changeset rather than in the
controller, so the Mastodon report API cannot file half a notice either (it has
no field for the declaration, so it cannot file one at all — a client sending
that category gets a 422).

**And the declaration is kept** (issue #2069). It was a virtual field only, on
the argument that a stored copyright report *is* the record that it was made —
which stopped being true the moment the public form (#2009) began demanding the
same declaration of **every** category, so the category answers a different
question than "was this declared?". It is now `moderation_reports.good_faith_declared_at`,
stamped by `Report.changeset/4` wherever the box was ticked (not only where it
was demanded), so the column has one meaning on every report however it was
filed. A timestamp rather than a boolean, like every other fact this table
records about a report; nil means no declaration on file, and rows filed before
the column existed stay nil rather than being backfilled into evidence nobody
recorded. The admin case page shows it beside the report's category chip
("in gutem Glauben erklärt"), which is the surface a rights holder's notice has
to be readable on. **And both forms word it identically** (issue #2068): the
public one used to add "that my statements are correct" and the member one did
not, which is two promises behind one column. It is one function component now,
`ReportHTML.good_faith_declaration/1`, beside `honest_reporting_note/1` — the
same channel `category_label/1` already travels, so the two forms cannot drift
apart again rather than being watched for drift.

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

Two things the ruling has to carry rather than assume. **The warning names the
ground the case page named**: the owner of a copyright case is told outright
that this is the law and not a house rule, and the warning that followed said
their content broke the community guidelines and linked them, so the two letters
about one case disagreed (issue #2067). `strike_ground/2` reads
`copyright_case?/1` and hands the mail `:copyright` or `:community` — for the
**owner** only, because a reporter's strike is for weaponising the report
button, which is a house rule whatever the case underneath was about. And
**what upholding does to the content is not one sentence**: the decision panel
promised "the content stays hidden" on every case, which is true for a frozen
post and false for the other three shapes an open case has, so
`uphold_content_effect/2` answers `:deleted` (a picture, hidden or not),
`:stays_hidden`, `:unhidden` (a profile or a page, where the consequence is the
strike) or `:untouched` (a flagged case that never hid anything). Beside it,
`pending_copyright_notice?/1` is what lets the picture caption tell the two
reasons a copyright case has not hidden anything apart — the category, or an
address nobody has confirmed yet.

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
A **picture** is the one type where the *category* also has a say: only a
copyright notice may hide one at all, and a reporter in good standing is still
what makes it happen — see "Only a copyright notice hides a picture" below.
A report needs no account at all: see "The notice from outside" below.

**Spam auto-defense:** distinct **spam-category** reports also freeze a whole
profile pending admin review once enough pile up (`@spam_freeze_reporters`, 5),
**even from untrusted reporters** — so a bot blasting the network is hidden in
minutes instead of waiting on an admin. The bar is kept higher than the two
trusted reporters so a small collusion ring cannot cheaply hide a rival; the
freeze is reversible (a rejected case restores everything and can mark the
brigaders' reports abusive).

Suspended/deactivated accounts cannot log in and disappear from feeds, profiles
and search.

House rules live at `/community`, and the rule about publishing only what you
hold the rights to links `/system/report` from the sentence that invites a
rights holder to use it — that word was plain text until issue #2068, with the
only way to the form sitting in the footer's Legal group.

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

**Every instant on that page is one an admin can read.** The header printed the
report time and the owner's 72h deadline as bare `Calendar.strftime` stamps in
universal time, two hours behind the same moments in the History timeline
directly beneath — which renders through `<.local_time>` like everything else in
the app — so an admin reading a deadline off the header was two hours wrong, in
the direction that makes them act too late (issue #2069). All three header
stamps are `<.local_time>` now: the admin's own zone when they have set one,
their browser's otherwise, in their date shape.

## A picture is reportable on its own (issue #2012)

A stolen profile picture used to be reportable only as the whole profile, which
a single report never hides — and even a frozen profile kept its pictures
online, because nginx serves those files straight off disk. `image` is the
report type for the picture itself: `fetch_content/2` resolves it through
`Vutuv.Images.Image`, the `images` row #2013 gave every profile picture and
cover, and the ⋯ menu on a profile offers "Report the profile picture" beside
the profile's own Report whenever that picture has a row.

**Only a picture the freeze can act on may be reported** (issue #2057). A row
in `images` is no longer proof of that: #2015 is moving four more picture kinds
into the table one at a time, and each arrives with a row a release before
anything can take it offline. So `reportable_by?/2` asks
`Vutuv.Images.takedown_ready?/1`, which reads the same `@takedown` map the
freeze itself dispatches on; the three releases of a kind's move are in
[images.md](images.md). A kind it refuses keeps the affordance it had before
its row existed: the member reports the post, the posting or the page the
picture sits on.

**Its freeze is a file move, not a column write.** `Vutuv.Images.freeze/1`
stamps `frozen_at`, clears the member row's four columns for that kind, and
moves every derived version, the private original and anything still in AI
quarantine into the picture's **takedown hold** — see the hold section in
[images.md](images.md) for what that tree is and why an interrupted move is
finished by itself. **`frozen_at` is the half a reader notices**: since #2027
every URL builder and every display gate resolves the picture through
`Vutuv.Images`, whose `servable?/1` and `shown_image/2` both answer "nothing
here" for a stamped row, so the
profile, the cards, the vCard, the link-preview JPEG and the ActivityPub icon
all fall back at once and the header draws the initials tile a member with no
picture gets. The four columns are cleared beside it because the release one
step back is still serving from them while the blue/green switch runs; they go
with the migration that drops them. Nothing is lost either way — the row holds
the same four values and the unfreeze writes them back.

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
the same reason. The refusal reads `frozen_at`, so it is about the **hold** and
not about the case: a picture a house-rule report only flagged can be replaced,
and that replacement overwrites the reported bytes, so
`Vutuv.Accounts.store_new_image/8` settles the open case as `resolved_deleted`
(the same outcome the owner's own "remove it" reaches). Otherwise an admin's
ruling — which for a picture is the one ruling that *deletes* — would land on
whatever the member put there afterwards.

**Only if the bytes really changed** (issue #2035). That settle first shipped on
the upload itself, and re-uploading the **same file** then closed the case,
dropped it out of the admin queue and told the reporters it was resolved — a
door out of a complaint that cost the owner nothing, in the categories (`family`,
`bullying`, `other`) where nothing was hidden in the first place, and equally in
the window a copyright notice from outside spends `flagged` while its notifier
has not confirmed it yet. So `store_new_image/8` reads the row's fingerprint
**before** the upsert replaces it and settles the case only when the new one
differs. The fingerprint is `sha256(original <> crop)`
(`Vutuv.Uploads.content_hash/2`), so a re-crop of the same original counts — the
picture everyone sees really is a different one — while the same file uploaded
again does not, and the case stays exactly where it was. Nothing is said to the
member about it: the case never promised that replacing the picture settles it,
and their upload succeeded.

### Only a copyright notice hides a picture (issue #2030)

The picture freeze first shipped on the ordinary trust ladder, and that was the
wrong dial: `trusted_reporter?/1` says yes to an account created a minute ago,
because nothing of theirs has been rejected yet. So a throwaway account took any
member's avatar off every surface with its first ever report, and the owner then
could not replace it. The split lives in
**`Vutuv.Moderation.report_freezes?/2`** — the one predicate both ways into a
freeze ask, and the one place a future author has to edit; `initial_status/3`
has a single clause and does no pattern matching of its own. It answers whether
a report of this category against this content type **may** hide it at all,
never whether it does — trust still decides that:

* **`copyright`** keeps the instant reach, and still only for a reporter in good
  standing. It is the legal notice the machinery exists for, `Report.changeset/3`
  already refuses it without a written explanation and a good-faith declaration,
  and taking the picture down promptly is the point.
* **`family` / `bullying` / `other`** — none of which requires so much as a note
  — open a `flagged` case and mail every admin (`:notify_admins_urgent`), leaving
  the picture where it is. That is exactly what a report against a whole profile
  already does, and a `flagged` case is in the admin queue by definition
  (`@queue_statuses`).

`maybe_upgrade_case/4` carries the same split on the other way in, so a second
house-rule report does not hide the picture either — two throwaway accounts are
barely more work than one — while a copyright notice joining an already-flagged
case freezes it on arrival. The owner is **not** notified for a flagged case, as
for every other flag-only case: nothing of theirs moved.

Two surfaces say which case they are in. The reporter's flash reads "our
moderators have been notified and will review this picture" when nothing was
hidden (the profile-report wording, which exists so a report that visibly
changes nothing does not feel inert) and the ordinary "we take it from here"
when the picture went offline. The admin case page reads the row's `frozen_at`
and either promises that rejecting puts every file back, or says the picture is
still on the profile — an admin ruling without knowing which is ruling blind.

**The reported picture is only visible on the case pages.** `GET
/moderation/cases/:id/image` authorizes owner-or-admin and streams the held
copy (or the still-served one, whenever a report only flagged the picture);
both the owner's case page and the admin's render it from that one route.
Without it an admin could not see what a copyright claim is about.

## A file is reportable on its own (issue #2109)

A file under a post can be a copyrighted paper or something not family-friendly,
and the post's Report button reports the post. `attachment` is the report type
for the file itself: `fetch_content/2` resolves it through
`Vutuv.Attachments.Attachment`, and everything the picture type learned in #2012
and #2030 applies with the file in the picture's place.

**Who answers for it is the parent, not the uploader.** `owner_id/1` matches on
the columns of the nullable parent pair — `post_id` first, then `message_id` —
and delegates to that row's own answer, so a file under a page's post carries
the same accountable member the post does (whoever claimed the page) rather than
whoever pressed upload. A file the composer still holds falls through to its
uploader, which is the only person it could ever be about.

**A file is as visible as the thing that published it.** `reportable_by?/2`
asks `Vutuv.Attachments.takedown_ready?/1` — published, and not already held —
and then the parent's own visibility (`Posts.visible_to?/2`, or participation in
the conversation). A file with neither parent is visible to nobody, so nobody
outside can report it, and a file another case has already taken offline answers
the same "not found" a picture does, for the same reason: telling a stranger it
exists is the leak.

**Its preview pages are not separately reportable.** The kind `attachment_page`
got its `@takedown` strategy in this change, and that registry is also what
`reportable_by?/2`'s catch-all `%Image{}` clause reads — so the refusing clause
had to arrive with it, or every page would have become reportable by whoever can
name a row id, with no visibility check at all. A page is our derivation of a
member's file; it has no address and no audience of its own, and reporting the
file takes its pages with it. That is why #2105 shipped the pages with no
takedown and said so.

**Only a copyright notice hides a file**, exactly as for a picture and by
`report_freezes?/2`'s own clause: `trusted_reporter?/1` says yes to an account
created a minute ago, and a house-rule complaint about what a post carries has
somewhere better to go — the post, which any trusted report does hide.

**The freeze moves the file and takes its pages along.**
`Vutuv.Attachments.freeze/1` stamps `attachments.frozen_at` first (the record of
the intent, so an interrupted move is finishable), freezes every
`attachment_page` row through `Vutuv.Images.freeze/1` — each page gets a hold of
its own, so `reconcile_holds/0` reaches it unchanged — and then moves both
copies of the file into `frozen/attachments/<attachment id>/`. That path is one
level deeper than a picture's on purpose; the hold section in
[images.md](images.md) says why. `Vutuv.Attachments.reconcile_holds/0` re-asserts
a half-done move, beside the image one in `Vutuv.Moderation.Sweeper`.

**Upholding deletes the file and keeps the post.** `uphold_content_effect/2`
answers `:deleted`, `settle_content_on_uphold/1` runs
`Vutuv.Attachments.purge/1` (every page, both copies, the held ones, the row),
and the post it hangs under is untouched — it was not what was reported.
Rejecting puts every file back where it was. The owner's self-service is
**remove or dispute**: there is no edit, because a file cannot be revised.

A file on a **post** offers the whole category list, including `spam` — unlike a
profile picture and for the press picture's reason: it is published content in
its own right and can perfectly well *be* the advert. A file on a private
**message** takes the message list instead, dropping `copyright`, because an
unpublished file is nothing for a rights holder to have taken down; that branch
is `report_categories/1`'s, since only the row knows which of its two parents it
has.

**The reported file is only readable on the case pages.** `GET
/moderation/cases/:id/file` authorizes owner-or-admin, reads the hold first and
falls back to the served copy, and hands the bytes over as a download under the
name the member uploaded them as — never inline, for an arbitrary document
authorized for exactly two people. Both case pages link it through that one
route, the twin of `/moderation/cases/:id/image`.

**What is not built yet.** Nothing serves an uploaded file or its preview pages
until #2108, so a file has no address at all — which means `ContentUrl` cannot
resolve one and the public notice form at `/system/report` cannot name a file,
and the post's card has no chip to hang a Report link on. Both are one clause
each for whoever ships that address.

## The notice from outside (issue #2009)

A photographer who finds their work on a post here is not a member, and until
this the only report form was behind `RequireLogin` — so the freeze that takes a
reported post offline in seconds never fired for the one complaint that carries
real liability, and the Impressum address was the whole mechanism.
**`/system/report`** is the way in without an account
(`VutuvWeb.PublicReportController`, linked from the footer's Legal group and
from the Impressum page). It takes the address of the content, a category, the
explanation, a name, an email and the good-faith declaration; all six are
required, which is stricter than the in-app form, where only a copyright notice
demands the last three (`Report.outside_changeset/3`). A member is identified by
their account and answerable through it; a stranger is answerable only through
what they wrote and the address they confirmed.

**The case is in front of an admin from the submit; nothing is hidden until
the confirmation.** `Moderation.file_public_notice/2` opens (or joins) the case
as `flagged`, which is a queue status, and mails a receipt carrying a
confirmation link
(`Emailer.public_notice_receipt_email/1`). The freeze, the owner's notice and
the urgent admin mail all wait for `confirm_public_notice/1`, which runs the
ordinary decision the trust ladder would have made at file time. The link is
good for **seven days** (`confirmation_expires_at`, checked inside the claiming
`UPDATE`); past that it confirms nothing, the page says so, and the sweeper
deletes the row and settles a case that was standing only because of it — a
link that never dies is a takedown anybody holding a forwarded copy of that
mail can set off a year later.

**Until it is followed the notice counts for nothing anywhere**, and "anywhere"
is the whole claim. `Report.effective?/1` is the rule and `Report.effective/1`
its query twin, so the SQL and the Elixir cannot spell it differently. Six
readers ask: `maybe_upgrade_case/4` (so five unconfirmed submissions cannot trip
the spam auto-defense and two cannot stand in for the two trusted reporters a
profile freeze needs), `trusted_reporters/2` and `stats_map/2`, and — found by
review, not by us — `copyright_case?/1`, `owner_notice/1` and
`notice_category_by_case/1`. Those last three are the ones that hurt: without
the filter an unconfirmed stranger turned an ordinary spam case into a
*copyright* case, which put their 2,000 characters on the owner's own case page
and in the owner's mail, and took the owner's self-service away — their edit
escalated instead of lifting the freeze. So the filter sits **inside** each of
those functions rather than at their call sites, and every owner-facing preload
goes through `Moderation.effective_reports/0`; the two admin surfaces keep the
plain `:reports` preload, because an admin has to see a notice whose address
nobody has confirmed yet (it is badged as such).

**The confirmation is a POST, not the GET the link lands on.** A link scanner in
a corporate mail gateway follows every URL in a message, and a GET that fires a
takedown would hand somebody's notice to whichever software opened their mail
first. The GET renders a page with one button; that button is the takedown. The
claim is one `UPDATE … WHERE confirmed_at IS NULL`, so two clicks in flight
cannot run the side effects twice.

**The URL is resolved, not trusted.** `Vutuv.Moderation.ContentUrl` asks
`Vutuv.Fediverse.local_path/1` whether the host is ours (which strips a leading
`www.` on both sides) and reads the path segments, so the `www.` alias, a
trailing slash, an appended `?utm_source=`, a fragment, a shouted host, plain
`http` and a dev port all name the same page. A post is resolved **by the id in
the path**, never by the handle beside it, which goes stale on a rename; a
member also answers to a retired handle. Beyond the profile, the post permalink,
the organization page and the job posting it resolves the two authorizing media
proxies (`/post_images/…`, `/post_videos/…`) to the post that carries them, and
the three addresses a profile picture has (`/avatars/<user id>/…`,
`/covers/<user id>/…`, `/<handle>/avatar.jpg`). **Only content an anonymous
visitor can already see resolves**, so the form is not an oracle for frozen,
deleted, restricted or members-only content — "we could not find that page" is
the honest answer for a typo and for a hidden post alike.

**A miss has three shapes and the notifier is told which** (issue #2068).
Answering "we could not find that page" about `/impressum` — an address that is
perfectly correct — sends a rights holder off to re-check a link that was right
all along, in the first minute of the one complaint that carries real
liability. So `resolve/1` answers `:foreign_host` (another server), then
`:not_reportable` (a page of the **site**: the Impressum, the house rules, the
member directory), and only then `:not_found`. Two questions decide the middle
one and both are asked without reading a row, which is what keeps the
anti-oracle rule intact. **Is the first path segment a reserved slug?** A
handle can never be one, so `from_segments/1` answers `:no_content_shape`
rather than letting its two greedy handle clauses read `/system/members/w` as
"the member `system`, missing" — that misreading is why every site page deeper
than one segment sat in the typo bucket. **And does the router put a fixed
address there?** `route_info/4` (asked about `Endpoint.host/0`, since
`local_path/1` has already ruled the address ours) matching a route whose
**first** segment is literal means a page of this installation;
`/system/members/:letter` and `/system/posts/:year/:month` qualify, while
`/:slug` does not — so a reserved word nobody routed, `/stefan`, is a name
still to be claimed and keeps the answer a typo gets.

Four things bound what a stranger can cause. The form is rate limited per client
IP **and per mailbox** (`VutuvWeb.RateLimit.check_public_notice/2`, 5 an hour
each), so the receipt mail cannot be pointed at a third party's inbox in bulk. A
partial unique index on `(case_id, reporter_email_key)` gives one mailbox one
receipt per piece of content however often it submits — the member-side
`(case_id, reporter_id)` index cannot do that job now the column is nullable,
because `(case_id, NULL)` never conflicts with itself in Postgres. **Both of
those count the mailbox, not the spelling**: `Report.canonical_email/1` strips a
`+tag` everywhere and dots at Gmail, since `victim+1@`, `victim+2@` and
`v.ictim@gmail.com` are one inbox and each was buying a fresh budget and a fresh
row. Dots are folded for Gmail alone, deliberately — everywhere else they are
significant and folding them would merge two different people. `reporter_email`
keeps the spelling an admin replies to; `reporter_email_key` carries the
counting. And the evidence screenshot fires on the **confirmation**, not the
submit, so an unauthenticated form is not a button that launches headless
Chromium.

**The receipt mail is built from the stored report, never from the values that
were typed**, and that is two bugs in one rule. An address pasted with a
trailing space stored fine (the changeset trims), was mailed raw, and the
`Emailer.deliver/1` chokepoint dropped it as malformed — so the page said the
mail had gone, none had, and the honest second attempt was refused as a
duplicate: the complaint was dead and could not be filed again. And
`reporter_name` reached a `.text.eex` body, which escapes nothing, still
carrying its line breaks, so a stranger controlled the recipient **and**
multi-line running text at the top of a DKIM-signed message from this
installation. The name is now collapsed to one line where it is **written**
(`UserHelpers.single_line/1` in `Report.outside_changeset/3`), so no later
surface has to remember, and the mail builder applies the same rule to the
pasted URL, which has no column to be cleaned in. That is `#2019`'s lesson one
level up: a stranger's text in a signed mail.

**`reporter_id` is nullable, and that touched every place assuming a user row.**
`Report.reporter_email` / `reporter_name` stand beside it under a CHECK
constraint that exactly one is set. `trusted_reporter?/1` takes a whole
`%Report{}` on this path and reads the ladder by **confirmed address**
(`trusted_reporter_emails/1`, the twin of `trusted_reporter_ids/1`); the
profile-freeze tally collects ids and addresses in two named private functions
(`member_reporter_ids/1`, `outside_reporter_emails/1`), because a nil in an
`IN` list falls out of the query with no stats row and reads back as
*trusted*. `report_stats/1` replaced `reporter_stats_map/1` on the admin case
page and is keyed by **report id**, since looking a notice up by its nil
reporter was a `KeyError` and a 500. `list_reporter_stats/0` is two grouped
queries now — its inner join to `users` dropped every outside notice from the
one screen whose job is showing who abuses the report button.
`Notifier.reporters_case_closed/1` branches on the column rather than on a
preloaded `%User{}`, so an outside notice gets its own mail instead of raising
in `deliver_to/2`, and `reject_case/3` marks an outside notice abusive without
trying to strike an account that does not exist (the mark still costs that
address its trust for a year). Severance never runs on this path:
`moderation_severances.reporter_id` is a NOT NULL foreign key and stays one,
and there is no tie to cut.

Admins see the notifier's **name and address** on the case page, plus an
"address not confirmed" badge while it is still pending; the owner of the
reported content never sees either. How the case ended reaches them through the
decision notice below.

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
where there is room for only one, the reporters' `notes`, `copyright?`, and
`from_member?`. The reporter is deliberately not in the map — a surface cannot
leak what it was never handed. `from_member?` is the one thing about them that
does travel, and only because the alternative was a lie: both surfaces explained
the automatic freeze as "a report from a **member** in good standing", which for
an outside notice (issue #2009) names somebody who has no account here and
points the owner at the wrong people (issue #2067). It says whether *any*
effective report on the case has a user row, never which one, so a case a member
and a stranger both reported keeps the member wording. The three surfaces are

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

That third surface is **one row per case, rewritten in place**, so its time has
to be the time of what the row currently *says*. It was the case's
`inserted_at`, the moment the report arrived, so a ruling days later kept the
row where it had always been, with the hour of the complaint on it, and the
member was never told their content had come back (issue #2067). Every reader of
the `moderation` kind in `Vutuv.Activity` — the ordering, the keyset cursor, the
`max` and the unread count — now asks `coalesce(resolved_at, inserted_at)`
through one macro, or the cursor and the ordering stop agreeing. It is the
answer `report_outcome` gives one kind over: stamp the event, not the trigger.

**The mail names what was actually reported**, which the body cannot derive from
a per-locale template: `VutuvWeb.ReportHTML.content_reported_sentence/1` gives
it one whole sentence per content type, pre-rendered in the recipient's language
beside the category labels. It is a sentence rather than a noun in a frame
because German inflects each kind differently — see `email.md` for why that is
the shape and not a placeholder.

Two more things the mail must not get wrong. **The options are the options that
case actually has**, and `Moderation.owner_edit_offer/2` answers that as one value
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

## Everyone who owns the page hears about it (issue #2120)

A moderation case carries **one** `users` foreign key, and it has to: that
member is the strike ladder. So when a page's press photo was taken down, the
mail, the line under the bell and the case page all reached
`Organizations.accountable_user_id/1` — the member who claimed the page — and
nobody else. A page run by a team could lose a picture without the people who
put it there ever hearing, and the 72 hours to dispute ran out in silence.

**What the case learned is the page, not a second owner.** `moderation_cases`
gained a nullable `organization_id`, written beside `owner_id` at the one place
a case is minted (`new_case_changeset/2`), and both come from one clause table:
`origin/1` answers `{owner_id, organization_id}` per content kind, with
`owner_id/1` and `organization_id/1` reading one half each. One table, because
for every kind a page can publish the two are the same fact read twice — the
owner *is* whoever claimed the page the content is on — and two tables would
have to learn the next author kind separately. A migration backfills the four
kinds that can already carry a page (post, image, attachment via its post, and
a case about the page itself); it was proven on the dev copy by seeding one
case per branch, since the real table holds none.

**Who hears is owners, and deliberately not the rest of the team.** #2087 split
*looking* at a page's Media Kit (any role, a recruiter included) from *writing*
it (owner or publisher). A takedown notice is neither: it is news for whoever
answers for the page, which is the `owner` role — the one the last-owner guard
guarantees exists, the one that can grant roles and hand the page on.
`Moderation.page_notice/1` names them, minus the member who carries the case,
who gets their own letter.

**Three surfaces, one rule each.** The notifications feed widens through
`told_about/2`, composed by both `owner_notified_cases_query/1` (the list, the
unread count and the newest-event arm all read it) and `open_cases_for/1`, so
the bell and `/moderation/cases` cannot show different sets. That predicate
resolves the member's page ids to a **list** rather than an `IN (subquery)`:
inside an `OR`, a subquery is a hashed SubPlan rather than an indexable qual, so
Postgres drops both indexes and scans the table — 8.678 ms against 0.018 ms on a
200k-row replica, paid by every member on every page load through `ShellLive`'s
unread count. Reading the case page is `case_readable_by?/2`; **settling** it is
`case_settleable_by?/2`, which is still `owner_id` alone and which the case page
asks before drawing the three self-service controls, so a control we draw and a
POST we accept are the same predicate.

**The letter is its own.** `page_content_frozen_*` (three locales × two bodies)
rather than a copy of `moderation_frozen_*`: that one offers a self-service
round a co-owner cannot take. It carries the same statement of reasons — the
reader can open the case page now, and a mail saying less than the page it links
to would only send them there to find out what happened — through
`statement_of_reasons/3`, whose `page_name` argument picks the voice of the one
sentence that differs (`ReportHTML.content_reported_sentence/2`, one msgid per
kind for the gender reason #2067 records). The in-app line branches on
`organization_name`, which `Activity.moderation_items/3` sets only for a reader
who is not the member the case is about, and which the live push carries too, so
the popup and the persisted row say the same thing.

**What did not change.** Accountability. The claimer still carries the case,
still gets the 72 hours, and is still the only member who can delete, edit or
dispute. A page whose claimer has deleted their account therefore stays
**un-reportable** (`accountable_user_id/1` is `nilify_all`, `can_report?/2`
refuses a nil owner) and only an admin freeze can act on it — widening the
notice does not change that, and handing an orphaned page's strikes to whoever
holds the owner role today would punish a member for an upload they may never
have made.

## The decision notice (issue #2011)

The mirror of the statement of reasons: the owner is owed the claim, and
whoever made it is owed the ruling. Until this, only an owner's *edit* told a
reporter anything — an admin upholding or rejecting, and the owner deleting,
said nothing at all — so somebody who reported a post went back to the URL for
days and eventually filed the same notice again. This is what the Digital
Services Act asks for (Art. 16); the reporter-facing text never says so.

`Notifier.reporters_case_closed/1` is the one place it happens, and all five
ways a case can close call it: `uphold_case/2`, `reject_case/3`, the owner's
delete (`content_deleted/1`), the owner's edit (`resolve_edited/2`) and the
erasing `remove_owner/4`. A member gets an in-app entry **and** a mail, an
outside notifier gets the mail alone. What it names is
`Moderation.reporter_outcome/1`'s word for the ending, and the four are not the
statuses renamed: `"upheld"` is deliberately not `"removed"`, because an upheld
case removes a picture, leaves a post frozen as evidence, and puts a **profile**
back with its owner on the strike ladder — telling that reporter the content was
removed would be false. It says what happened to the *content* and never what
happened to the account behind it: a warning, a suspension or nothing visible at
all is between that member and us, the same asymmetry that keeps the reporter's
name off the owner's case page.

**What happened to the content is measured, not derived from the ending.**
Because those four words cannot carry it, the upheld letter said only "we have
taken the necessary steps" and told the one person it is addressed to nothing at
all — a promise this issue made and did not keep (fixed in #2067).
`Moderation.reported_content_fate/1` answers `:removed`, `:hidden` or `:visible`
by **looking**, after the ruling has settled the content and before any delivery
task is spawned: the row is gone, or it is frozen, or its owner is hidden and
takes everything they own with them (`account_hidden?/1` — otherwise the account
removal an admin has just carried out reads to the reporter as "still visible").
It is read once per closing case and travels to both builders as `content_fate`,
so a member and an outside notifier are told the same thing.

**Two closing paths cannot be measured, and both said the friendly thing until
they were fixed.** `remove_owner/4` on `:delete` has to tell the reporters
*before* it erases the case, so a measurement there answers "still on vutuv"
about an account that is gone a line later; it is the one caller that passes
`fate: :removed` to `Notifier.reporters_case_closed/2`, stated by the call that
makes it true. And **replacing** a flagged picture leaves the row standing with
its id (issue #2035) and somebody else's bytes in it, so a measurement answers
"still visible" — while the case, closed as `resolved_deleted`, put "was
deleted" in the subject. That one is fixed at the source rather than in the
body: a replacement is a **revision** (`Moderation.content_replaced/1`,
`resolved_edited`), which also spends the owner's one self-service round on that
picture, as it should.

That second bug is what `Moderation.consistent_outcome?/2` guards. The subject
comes from the case status and the fate paragraph from a measurement — **two
sources on purpose**, one saying who decided and what they did, the other what
the content is now — and exactly two of the four endings make a claim about the
content in their own subject, so each of those has exactly one fate that agrees
with it.

**It is asked in `Notifier.deliver_or_refuse/4`, where the letter's two halves
meet** (issue #2071). For its first weeks it was called from a test alone, and
that test handed it the fate it expected rather than the one the system produced
— so it compared a sentence with itself and would have passed whatever the code
did. A tenth closing path proved it: a caller reaching for the public
`content_deleted/1` on content that is merely frozen closes the case
`resolved_deleted`, whose subject says the content was deleted, over a measured
fate of `:hidden`. When the guard fires **nothing is sent** — a letter that
contradicts itself is worse for its reader than none, and this one is a legal
notice — and the claim the stamping `UPDATE` staked is **handed back**, because
leaving `outcome_notified_at` set would record that these reporters were told,
which is false. `Logger.error` names the case, its status, both halves and how
many reporters are owed. The regression test walks that tenth path through the
public API rather than asserting on the predicate, so it sees what the system
produced.

**It belongs at the mail, and moving it into the close path would be worse.**
The two sources are answering different questions — the status says what
somebody *did*, the fate says how the content *stands* — so the close path has
nothing to repair. A guard there could only refuse the *close*, which turns a
wording bug into a failed member action on content they have already changed.
The remedy for a fired guard is always a source change in whichever caller
picked the wrong status, which is exactly what #2067 was, twice: `resolved_edited`
for a replaced picture, and `fate: :removed` stated by the account deletion.
Detecting it earlier would not change that.

**Refusing is right; refusing for ever is not.** An operator reading a log is
not a recovery plan, and the record already exists — `Report.awaiting_outcome/1`
still says these reporters are owed a notice. What is missing is anything that
comes back to such a row, which is **#2073**. Until then a fired guard is
silence for that reporter, and the wrong *ending* still stands too: the status,
its `resolved_at`, the History entry and, on `resolved_edited`, the owner's
spent self-service round.

**A guard here is a refusal to speak, so it must name the contradiction and not
a hair more.** `"revised"` rules out only `:removed`: the subject says the owner
rewrote the content, and the sole fate calling that a lie is one saying the
content is gone. Demanding `:visible` instead looked tighter and refused a true
letter on a live path — `account_hidden?/1` counts `frozen_at` and
`unreachable_at`, neither of which blocks signing in, so an owner hidden by an
**unrelated** case can still edit or replace reported content and close
`resolved_edited` over a measured `:hidden`. Two true sentences, one refused
notice, and that reporter heard nothing at all (caught in review on PR #2072).

**Exactly once is a claim, not a convention.** One `UPDATE` both picks the
reports that still owe their reporter a notice and stamps
`moderation_reports.outcome_notified_at`, and only the rows it returns are
delivered to — so a second close, a retry, or two admins ruling in the same
instant find nothing left to claim. Every value the mail needs is read off that
returned row before the delivery task is spawned, because `remove_owner/4` on
`:delete` erases the case and its reports while the mail is still in flight, and
a task that went looking for the row again would find nothing and quietly send
nothing. That deletion is also why the reporters are told **before** the account
goes, and why on that one path their in-app entry disappears with the row while
their mail stands.

**Two reporters are deliberately left out**, and `Report.awaiting_outcome/1`
holds both. An **unconfirmed** outside notice is not answered: nobody proved
they can read that address, the receipt is the one mail it earns, and a decision
notice to an unverified claim would confirm to a stranger that the content
exists. A report an admin marked **abusive** is not answered either: the notice
exists so a good-faith reporter stops checking the URL, and a member just called
a deliberate weapon is already hearing about it through the strike ladder.

The in-app entry is the `report_outcome` kind in `Vutuv.Activity`'s registry,
derived from the stamped report row through
`Moderation.reporter_outcome_query/1` — so the line under the bell and the mail
read the same ending, and a case closed without anybody being told has no line
either. It carries no actor and links nowhere: the case page belongs to the
owner and the admins (`ModerationCaseController.authorize/2`), and the content
may be gone.

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
