# Settings & account

How members manage their own account: the settings hub, onboarding, username
changes, the LinkedIn import and the GDPR data export. Login and sessions are
covered in [authentication.md](authentication.md).

## Settings hub (user-agnostic `/settings` URLs)

Everything a member can change about themselves lives behind **one map** —
`vutuv.de/settings`, iOS-Settings-style grouped rows. `VutuvWeb.UI.settings_menu/1`
is that map's single source: the hub and the desktop sidebar both render it, so
they cannot drift. If an editable area is not on it, it does not exist.

**Five groups**, each named for its own subject and at most eight rows long:

| Group | Holds |
| --- | --- |
| Profile | Basics & photos, Username, Experience, Education, Certificates & licenses, Language skills, Tags, Organizations |
| Contact details | Email addresses, Phone numbers, Addresses, Websites & links, Social media profiles, Messengers |
| Notifications & feed | Notifications, Muted words & tags, Tags you follow, Saved searches |
| Privacy | Visibility, Blocked members, Fediverse |
| Account | Sign-in & security, Account activity, Language & display, Import, Export, Apps & API, Delete account (red) |

Each row is a map with `:key` (the sidebar's active state and the hub's entry
counts), `:label`, `:path`, a `:hint` line saying what is inside, `:terms`
(never-rendered search synonyms) and `:danger`. Rows are **unconditional** — a
menu that changes shape between visits cannot be learned, and a hidden row is
unfindable, so "Tags you follow" and "Saved searches" are always listed and
their pages explain themselves when empty.

Above the map sits a **filter box** (`[data-settings-filter]` in `app.js`) that
matches each row's label, hint and synonyms and hides the groups that empty out.
The synonyms are what make it worth having: "Passwort", "Handle" or "abmelden"
find the right page although no label uses those words. It is a progressive
enhancement — with JS off the box simply is not wired and the map below works.

This replaced a flat 25-row list in three groups (Profile / Account / **More**),
whose junk-drawer last group held Privacy and Notifications behind seventeen
other rows, and whose desktop hub was a sidebar beside an empty pane reading
"pick a section on the left". The same cards now flow into two columns from md
up (CSS multicol, so groups of wildly different heights leave no ragged gaps),
which is one list at every width instead of a phone list plus a desktop
placeholder.

The URLs carry **no username**: `/settings/links` always opens *your own* link
editor, so the same URL works for every member (handy in support answers).

Two pages that are settings in everything but their URL wear the same shell:
the **blocked list** at `/blocks` (linked straight from profiles and post menus,
so the path stays) and the **export corner** at `/:slug/export` (profile-scoped
because it hosts the public CV builder link).

Every profile section is two pages: the **public showcase** at `/:slug/links`
(identical for every viewer, the owner included — private e-mail addresses never
render there) and the **editor** at `/settings/links` (add tile, reorder,
edit/delete, inside a shared shell: "‹ Einstellungen" back link on phones, a
persistent sidebar on md+).

The owner's only affordance on a public section page is a quiet "Verwalten ›"
bridge in the header; the old "Ansehen als" switcher disappeared from section
pages (there is nothing to preview any more) and remains only on the profile
itself.

The account areas are focused subpages: Sign-in & security
(`/settings/security` — how you sign in, signed-in devices, passkeys, login
codes, and the last few account events), Account activity
(`/settings/activity` — the full log of what changed on the account and when,
see [account-activity.md](account-activity.md)), Language & display
(`/settings/preferences`), Import
(`/settings/import/linkedin`), Export (`/:slug/export`, the profile-scoped export corner) and Delete account
(`/settings/delete`). "Profil bearbeiten" jumps to the basics form
(`/settings/profile`), which ends in links to the sibling sections; the old
owner URLs (`/:slug/edit`, `/:slug/settings/*`) redirect to their `/settings`
twins. The Language & display page carries the member's own **reading
preferences**: interface language, map services, and **post display** (how many
lines a post is clamped to before "Read more" and whether the body hyphenates,
desktop and mobile independently — 0/empty means no truncation; posted to
`/settings/post_display`, read back by `Vutuv.Accounts.User.post_prefs/1`, see
`docs/architecture/posts-and-feed.md`). The same card sets how many lines of a
post a **notification quotes** (`:notification_post_lines`, shipped default 5,
read back by `Vutuv.Accounts.User.notification_post_lines/1`, see
[realtime.md](realtime.md)); that one has no 0 mode — a quote is always cut —
so an empty field means "inherit the site default" rather than "never shorten".

### Notifications (`/settings/notifications`)

Three cards. **Email notifications**: one positive flag per type (unread
messages plus its frequency/delay pair, endorsements, new followers, the
newsletter), each with a one-click unsubscribe in the mail itself — see
[email.md](email.md). **CV updates**: the one in-app notification kind a member
can switch off (`cv_update_notifications?`, default on), because it is the only
one triggered by someone else's housekeeping rather than by something done to
them — see the CV updates section in [realtime.md](realtime.md). **In-app
notifications**: a read-only explainer of the rest, which are always on.

### Member preferences with installation defaults (`Vutuv.Prefs`)

The map and post-display settings are the first citizens of the generic
**preferences system**. Every such knob is declared once in the
`Vutuv.Prefs.registry/0` (key, type, shipped default, constraints, group) and
resolves in three layers: the member's **explicit value** (a non-nil `users`
column; an explicit `0`/`false` is a choice) → the **installation default**
(admin-set at `/admin/preferences`, stored in `pref_defaults`, cached in
`Vutuv.Prefs.Cache` via `persistent_term` + a PubSub reload on every node) →
the **shipped default** from the registry. The pref columns are nullable with
no DB or schema default — nil means "inherit", so an admin's default change
reaches exactly the members who never chose for themselves (and every
logged-out visitor). Render sites never read the raw columns; they resolve
through `Vutuv.Prefs.get/2` (or its seams `User.post_prefs/1`, `Vutuv.Maps`).

The three GUIs are registry-generated, so a new pref only needs an additive
migration (nullable column), a registry entry (+ `label/1`; anchor the msgids
in `VutuvWeb.GettextExtractionAnchors`) and a home on a /settings page:
`/admin/preferences` edits the installation defaults (rows equal to the
shipped default are deleted, per-pref counts show how many members customized),
`/admin/users/:id/preferences` sets or clears one member's values for support
(blank = back to inherit; same columns as the member's own save, so nothing is
hidden from them), and the member's own forms on `/settings/preferences`
render the **effective** values (`Prefs.with_effective/1`) with a quiet
per-group "Reset to the site defaults" link (POST `/settings/<group>/reset`)
that nils the group. Saving a form stores explicit values, after which the
member no longer follows future default changes for those fields — the reset
link is the way back. `test/vutuv/prefs_test.exs` guards the registry
invariants (every key a nullable schema field with its default only in the
registry). In tests the cache process is off (`config :vutuv,
:prefs_defaults_cache, false` — its reloads would touch the SQL sandbox from
outside), so resolution falls back to shipped defaults; tests inject
installation defaults with `Vutuv.Prefs.Cache.store/1` + `clear/0`
(async: false).

The **add-tag form** (`/settings/tags/new`) is a LiveView
(`VutuvWeb.TagNewLive`, issue #848): while the member types it previews the
tags a submit will attach — split on commas and spaces, leading `#` stripped,
matched case-insensitively against the existing global tags (whose stored
display name wins, so a camel-case variant of an existing lowercase tag
previews as the lowercase chip the profile will actually show), duplicates
collapsed. `Vutuv.Tags.preview_tag_names/1` computes the preview, and the save
path dedupes the same way, so preview and outcome always agree. The public tag
page's "Add this tag" button still POSTs to the dead
`UserTagController.create`, which now always redirects.

## New-member onboarding

Sign-up requires **at least three distinct tags** (tags are how members are
found; validated in `User.registration_changeset/2` with the same comma/space
parsing and case-insensitive de-duplication the tag creation uses).

After the confirmation PIN a fresh member lands on their own profile, where the
**"Complete your profile" checklist** (owner-only, first hour after sign-up —
`UserProfileLive.@onboarding_window_seconds`) opens with the tag step already
checked — 1/5 done — and leads through photo → tagline (Kurzbeschreibung) →
**first post** (suggesting a topic from the member's own tags, "Zum Beispiel
ein Gedanke zu #elixir") → **"Follow 5 members"**. The follow step shows the
running count as its hint, ticks off live when the fifth follow happens on the
page itself, and links to the "Who to follow" card — or, on an installation
with nobody to suggest, to the most-followed listing.

While the owner follows fewer than five members
(`UserProfileLive.@discovery_follow_target`), the profile also renders the
**"Who to follow" card promoted at the top of the rail** (`data-promoted`,
plus an intro line saying that the feed is built from followed members)
instead of its regular late-rail spot: every other card on a fresh profile
points inward, and this is the one moment to show that there are people here
to follow. The placement is sticky per page view — the fifth follow, made from
the promoted card itself, must not teleport the card away mid-click; the next
visit demotes it. The suggestions are the last four weeks' most-hearted
posters (`Posts.top_recent_posters/2`,
`UserProfileLive.@suggested_window_days`): members with a post in the window,
ranked by the local hearts those posts collected (post count breaks ties),
then thinned by the per-viewer exclusions (owner, viewer, already-followed,
blocked). Follower totals deliberately play no part — they reward the past,
while the card's promise is a feed with something in it, which only current,
liked output can keep. Deliberately strict, so a thin card beats a padded
one; an installation with no recent posts renders no card, and the checklist
step then links to the most-followed listing instead.

Work experience is deliberately not on the checklist; its section card keeps its
own add tile.

## Username (@handle) changes

The username has its own page under **Profile**, `/settings/username`: the
everyday `vutuv.de/<handle>` address with a copy button, the rename form, and
the permanent id-based profile link (issue #904) as the answer to "but then my
old links break". A handle is public identity, not a credential, so burying it
under Sign-in & security — where it lived until #1083, along with the permanent
link — was the single clearest example of the old menu's problem. That page
keeps a signpost row; `/settings/usernames/new` redirects here.

Handles follow the Twitter username mechanism: letters, digits and underscores,
`Vutuv.Handles.min_length/0` to `max_length/0` characters, stored lowercase,
unique (`users.username` carries the unique index; the `handles` registry adds
the cross-table lock with organizations), never a reserved route word; the form
checks availability live while typing (`GET /settings/usernames/availability`).

**Renaming propagates.** Because an `@handle` mention is plain text in a body
(resolved to a link only at render time — see [mentions.md](mentions.md)), the
rename rewrites every stored `@old` to `@new` across all mention surfaces and
notifies the author of each rewritten **post** ("@old renamed to @new", with the
affected posts). Two rules keep that from being abused: a new handle is only
available if it is **used in no post** (else claiming it would hijack those
links), and a body may only mention handles that **exist** (else `@wanted` could
be seeded to reserve it). The whole rewrite runs inside the rename transaction,
so it is all-or-nothing. The old handle is then freed — and, being rewritten out
of every post, safely reclaimable.

Changes are limited to 4 per rolling 90 days (counted via the `username_changes`
ledger) and the form spells the quota out, including the next possible date once
it is used up; it also previews how many posts the rename will update.

### Renaming is re-confirmed (issue #1086)

A rename is a public-identity change that frees the old handle for anyone to
claim, so — like adding an email address and deleting the account, its
neighbours on the settings menu — it asks the member to prove it is them.
Before this, a live session was the only thing between a borrowed laptop and
all of it.

It is a **two-step flow**. `UsernameController.create` runs
`Accounts.validate_username_change/2`, a dry run of every rename rule (grammar,
availability against **both** `users.username` and the `handles` registry,
reserved words, used-in-a-post, "already your username", quota) that writes
nothing, then remembers the handle in the **session** and renders
`/settings/username/confirm`. Nothing is renamed until step 2, and
`update_username/2` re-runs all of it inside its transaction, so a handle that
goes stale in between still cannot slip through.

Step 2 takes whichever factor the member has, all converging on one commit path:

| Factor | How |
| --- | --- |
| Passkey | `POST /settings/username/passkey/challenge` + `/passkey` (JSON, driven by `assets/js/webauthn.js`). Verifying only **stamps the session** (10 minutes, one use); the JS then submits the ordinary confirmation form, so the rename keeps its single CSRF-protected exit. The assertion's owner is checked against the signed-in member — otherwise any member's passkey would confirm any other member's rename. |
| Authenticator app / one-time list code | Typed into the same field as the PIN, via `Accounts.check_confirmation_code/3` (the logged-in twin of `check_login_code/2`). |
| Emailed PIN | `Emailer.username_change_email/4`, a `"username"`-type `LoginPin` whose payload is the pending handle. The mail **names the handle** it authorizes and says what to do if it was not requested. |

The pending handle survives a trip back to the form: `new/2` deliberately does
**not** clear it, because a GET must be safe and `/settings/username` is reached
by accident constantly (sidebar row, breadcrumb, Back button, link prefetch).
Clearing there made any of those silently destroy a confirmation in progress, so
the member's correct PIN answered "this confirmation expired" with nothing on
screen to explain why. It ages out after 30 minutes instead, alongside the PIN.

**Which address gets the PIN** is the member's choice when they have several
(`Accounts.list_email_values/1` fills the picker **and** is the allow-list the
submitted address is checked against — without that check the picker would be a
relay for mailing a valid PIN to an attacker's inbox). A member with one address
and no enrolled factor is asked nothing: the PIN is sent as step 1 completes, so
their flow is the familiar "type the number from your inbox". A member who *has*
a passkey or an authenticator app is **not** mailed unasked — an unrequested PIN
should read as an alarm, not as noise. Sends are throttled by
`RateLimit.check_username_pin/2` (5/hour), attempts by `:username_change_confirm`.

The rename is also **recorded**: `username_changed`, both handles and the
confirming factor land in the member's account-activity log (issue #1087, see
[account-activity.md](account-activity.md)), so "my username is different and I
did not do that" has an answer with a timestamp on it.

## Import from LinkedIn

On its own settings page (`/settings/import/linkedin`, owner-only) a member
uploads their LinkedIn **data-export ZIP** (the page walks them through
requesting the "larger data archive" on LinkedIn, with a direct link and a
screenshot) and vutuv pre-fills their profile from it
(`Vutuv.Imports.LinkedIn`).

The upload accepts **drag-and-drop** (a progressive enhancement over a plain
file input, so it still works with JS off).

The parser is filename-independent (it classifies each CSV by its header
signature, since LinkedIn localizes the names), tolerates a UTF-8 BOM and CRLF,
and maps Positions → work experiences, Volunteering → work experiences with
the volunteer category (issue #840), Education → the new education section,
Skills → tags, and the profile's Websites / Twitter handles → links / social
accounts; `Connections.csv` is skipped and email addresses are shown read-only
(never auto-created, since each is PIN-verified).

It is **preview-and-confirm**: the member sees everything found, entries already
on their profile are pre-unchecked, each section has a **select-all /
deselect-all** toggle, and nothing is written until they confirm.

The apply step runs in one transaction, skips duplicates (so a re-import never
doubles a row) and fills only blank name/headline fields (an import never
overwrites existing content).

Safeguards: the upload is capped (20 MB), the archive is inspected via its
central directory **before** any decompression and rejected on a zip-bomb
signature (per-entry / total-uncompressed / entry-count caps, and
unrecognized/huge members are never inflated), imports are rate-limited per
member, the CSVs are only ever decompressed into memory (never written to disk),
and the uploaded temp file is deleted as soon as it is read.

## Data export (GDPR)

Every member can download everything vutuv stores about them as one JSON file
from their export corner (`/:slug/export`; the file is
`/:slug/export/download`). The settings-era URLs (`/settings/export`,
`/settings/export/download`) redirect there.

Strictly owner-only — it includes private data (all email addresses, direct
messages, ad bookings).

`Vutuv.Export` builds the document; a new per-user subsystem must add its
section there (just like `Accounts.delete_user/1` must learn to delete it). The
account-activity log is one of its sections — and downloading the export is
itself an entry in that log.

## CV (Lebenslauf) — `/:slug/cv`

Every profile can be turned into a formatted CV for a job application, at its
own **public** URL `/:slug/cv` (issue #841). It is public like the profile:
the profile rail links it for every visitor, and each document is built
through the viewer's eyes (`VutuvWeb.CV.build/2` takes a `:viewer`) — only the
email is viewer-sensitive, so a private address appears solely in the owner's
own download. The owner also finds a link to it from their data page
(`/:slug/export`), which otherwise hosts the owner-only GDPR dump.

**`/:slug/cv` is an interactive builder** (`VutuvWeb.CVLive`, embedded by
`VutuvWeb.CVController.show` via `live_render`, the profile's pattern). The
left column is the CV as an include/exclude checklist — every identity field
(name, photo, tagline, email, phone, address, profile link, date of birth,
gender), every section and every single entry has a toggle, plus an
**Anonymize** preset that hides the name, photo, contact details, personal
details and social media accounts in one click. The right column is the
download panel. So a recruiter can drop sections, tailor the CV to a role, or
forward a bias-free anonymized version. Nothing is persisted: the selection
lives in the socket and is encoded into every download/print link as
`?hide=<comma-separated keys>` (identity keys, section keys — a work/education
category or `tags`/`qualifications`/`languages`/`links`/`social_media` — and
entry UUIDs), which `CVController` parses and `VutuvWeb.CV.apply_hide/2`
applies before rendering.

`VutuvWeb.CV.build/2` produces one keyed data map, kept in step with the
profile as sections are added: the issue #840 work-experience categories in CV
order (employment, internships, volunteering), education in its issue #849
categories (university, apprenticeship, school — collapsed to one "Education"
section for the common degrees-only member, like the profile), tags, spoken
languages (#865), certificates & licenses (#859), links, social media
accounts, the member's **first** email / phone number / address as contact
details, and the personal details (date of birth, gender). Whenever a new
profile data section ships, add it here too.

One renderer per format, all dependency-free (nothing for an air-gapped
install to configure):

- **Print view** (`/:slug/cv/print`): a self-contained HTML document with an
  `@media print` A4 setup. **PDF = the browser's print dialog** on this view;
  there is no server-side PDF renderer (yet — that would be an external binary
  behind a config flag, split into #853).
- **Downloads** (`/:slug/cv/download/:format`): `html` (the same document),
  `tex` (plain `article`-class LaTeX, all specials escaped), `docx` / `odt`
  (minimal OOXML / ODF ZIP packages built with Erlang's `:zip`), and `json`
  (the [JSON Resume](https://jsonresume.org) schema; internships join `work`,
  volunteering maps to `volunteer`, spoken languages become `languages`,
  certificates `certificates`, links and social media accounts
  `basics.profiles`). Every format is a member-initiated export of the same
  public CV, so all of them — the machine-readable `json` included — stay
  public like the profile page itself, even for a fully machine-opted-out
  member (`noindex?` + `noai?`).
