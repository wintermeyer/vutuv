# Settings & account

How members manage their own account: the settings hub, onboarding, username
changes, the LinkedIn import and the GDPR data export. Login and sessions are
covered in [authentication.md](authentication.md).

## Settings hub (user-agnostic `/settings` URLs)

Everything a member can change about themselves lives behind **one map** —
`vutuv.de/settings`, iOS-Settings-style grouped rows (Profile sections with live
entry counts / Account / Privacy, Notifications, Apps, and a red "Delete
account" door).

The URLs carry **no username**: `/settings/links` always opens *your own* link
editor, so the same URL works for every member (handy in support answers).

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
(`/settings/security`), Language & maps (`/settings/preferences`), Import
(`/settings/import/linkedin`), Export (`/:slug/export`, the profile-scoped export corner) and Delete account
(`/settings/delete`). "Profil bearbeiten" jumps to the basics form
(`/settings/profile`), which ends in links to the sibling sections; the old
owner URLs (`/:slug/edit`, `/:slug/settings/*`) redirect to their `/settings`
twins.

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
**"Complete your profile" checklist** (owner-only, first 24h or 24h after a
dormant return) opens with the tag step already checked — 1/4 done — and leads
through photo → tagline (Kurzbeschreibung) → **first post**, the last step
suggesting a topic from the member's own tags ("Zum Beispiel ein Gedanke
zu #elixir").

Work experience is deliberately not on the checklist; its section card keeps its
own add tile.

## Username (@handle) changes

Members change their username at `/:slug/usernames/new`, linked from the
edit-profile sidebar.

Handles follow the Twitter username mechanism: letters, digits and underscores,
3 to 15 characters, stored lowercase, unique (`users.username` carries the
unique index; there is no slugs table), never a reserved route word; the form
checks availability live while typing (`GET /:slug/usernames/availability`).

Renaming frees the old handle immediately: no redirect, no reservation, anyone
can claim it.

Changes are limited to 4 per rolling 90 days (counted via the `username_changes`
ledger) and the form spells the quota out, including the next possible date once
it is used up.

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
section there (just like `Accounts.delete_user/1` must learn to delete it)

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
(name, photo, tagline, email, phone, address, profile link), every section
and every single entry has a toggle, plus an **Anonymize** preset that hides
the name, photo and contact details in one click. The right column is the
download panel. So a recruiter can drop sections, tailor the CV to a role, or
forward a bias-free anonymized version. Nothing is persisted: the selection
lives in the socket and is encoded into every download/print link as
`?hide=<comma-separated keys>` (identity keys, section keys — a work/education
category or `tags`/`links` — and entry UUIDs), which `CVController` parses and
`VutuvWeb.CV.apply_hide/2` applies before rendering.

`VutuvWeb.CV.build/2` produces one keyed data map: the issue #840
work-experience categories in CV order (employment, internships,
volunteering), education in its issue #849 categories (university,
apprenticeship, school — collapsed to one "Education" section for the common
degrees-only member, like the profile), tags, links, and the member's
**first** email / phone number / address as contact details.

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
  volunteering maps to `volunteer`). The machine-readable `json` is the one
  format withheld — it answers 404 for a fully machine-opted-out member
  (`agent_docs_blocked?`, whose agent `.json` also 404s) to everyone but the
  owner; the human-use formats stay public like the profile page itself.
