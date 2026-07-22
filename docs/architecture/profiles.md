# Profiles

What a member's profile shows and where the data comes from. The profile page
itself is a LiveView ([realtime.md](realtime.md)), every public profile page
has agent-format siblings ([agents-and-seo.md](agents-and-seo.md)), and
members edit all of it from the settings hub
([settings-and-account.md](settings-and-account.md)).

## Owner vs. public view

A signed-in member always sees their **own** view of any profile (their own or
someone else's). There is no owner "view as public" toggle: to see the public
view a member logs out. The anonymous public view — the same one search engines
and the agent-format siblings get — hides owner chrome and private data (private
emails are owner-only) and enforces post visibility server-side, so restricted
content never reaches the anonymous HTML. A stale `?view_as=` query string is
inert (the profile ignores it).

The profile-section pages behave the same way: `/:slug/<section>` IS the public
view for everyone, and editing happens at `/settings/<section>`.

## Birthday visibility (General Info card)

A member enters their birthday on the Basics form but chooses **how much of it
is public** with the neighbouring `users.birthdate_visibility` select. Unlike
the three-way audience gate below, this is a **granularity** knob that applies
to every viewer alike:

| value       | profile shows            | agent formats                        | public CV        |
| ----------- | ------------------------ | ------------------------------------ | ---------------- |
| `full`      | full date + age (default)| `birthdate` (ISO) + `age`            | full date        |
| `age`       | age only                 | `age` only                           | no DOB line      |
| `day_month` | day + month, no year     | `birthday_month_day` (`MM-DD`)       | day + month      |
| `hidden`    | nothing                  | nothing                              | no DOB line      |

`Vutuv.Accounts.User.birthdate_mode/1` is the single seam — it folds `hidden`
and "no birthday set" into one `:none` so a call site gates the whole display on
one value (a nil/legacy setting falls back to `:full`, the historical public
behaviour, so existing members are unchanged). The profile card
(`show.html.heex`), the anonymous agent docs (`ProfileDoc` merges gated
`birthdate` / `birthday_month_day` / `age` fields, so md/txt/json/xml and the
vCard's `BDAY` — which is only emitted for the full date, vCard 3.0 having no
year-less form — stay in sync) and the **public** CV builder (`VutuvWeb.CV`,
`/:slug/cv`) all read it, so none of them can reveal more than the profile does.
The owner's own **GDPR export** and the admin **newsletter age segmentation**
deliberately keep the raw stored `birthdate` — the setting is about public
display, not deletion. `birthdate_visibility_test.exs` asserts both sides of
each of the four modes across every surface.

## Employment-status badge & visibility (issues #870, #928)

Members can advertise a job-availability signal shown as a small pill in the
profile header, right under their name: `users.employment_status` is `nil` (not
specified, no badge), `"open"` (employed but open to offers) or `"looking"`
(actively looking). The wording lives once in
`Vutuv.Accounts.User.employment_status_label/1` — shared by the pill
(`VutuvWeb.UI.employment_status_badge/1`), the Basics-form select
(`UserHelpers.employment_status_options/0`) and the agent docs — so they can
never disagree.

**Who sees it** is a per-member choice, `users.employment_status_visibility`
(`"everyone"` / `"members"` / `"hidden"`, NOT NULL default `"members"`):

- `"everyone"` — every visitor, including logged-out ones, crawlers and the
  agent-format siblings. This is the SEO/GEO story: only an `"everyone"` status
  reaches the crawlable HTML and the `.md`/`.txt`/`.json`/`.xml` documents.
- `"members"` (the default) — only a signed-in member. A safe default beats a
  maximal one, and the Basics-form helper text is honest that it *reduces* but
  cannot *guarantee* who sees it, since anyone (an employer included) can create
  an account. The owner, being a signed-in member, sees their own badge.
- `"hidden"` — nobody, not even the owner on their own profile; the status stays
  stored and can be re-shared later.

The three visibility values and their labels are shared (`User.visibilities/0`,
`User.visibility_label/1`) with the salary expectation below. The rule itself is
one seam, `User.employment_status_visible?/2` (returns false when no status is
set, so a call site gates the whole badge row on it); it delegates to a private
`visibility_allows?/2` that the salary predicate reuses. The profile template
passes the viewer (`@current_user`); `ProfileDoc` passes its `:viewer` — `nil`
for the anonymous extension URLs (so `"members"`/`"hidden"` drop out), the
token's member for an authenticated `/api/2.0` read (so a `"members"` status
shows there). Because the profile is a LiveView, changing the setting in
`/settings/profile` reflects on an open profile without a reload.

## Salary expectation / Gehaltsvorstellung (issue #928)

A member may state a **minimum** salary expectation, stored as
`users.desired_salary_min` (a whole-currency-unit **integer**, `nil` = not
stated — the codebase models money as integers, never `:decimal`, and the
display uses the integer-only `delimited_count/1`), plus
`desired_salary_currency` (whitelist `EUR`/`USD`/`GBP`/`CHF`, default `EUR`),
`desired_salary_period` (`hour`/`day`/`week`/`month`/`year`, default `year`) and
its own `desired_salary_visibility` (the shared three-way enum, default
**`hidden`**). There is deliberately **no** current- or past-salary field: the
EU pay-transparency directive bans that employer question, so we don't collect
it either.

The field's real job is **matching, not display**: even at `hidden` it will feed
the member's own job-board filter and skip alert postings below the minimum
(milestone issues 6/9 and 8/9). `desired_salary_visibility` only governs who
*else* sees it, through `User.desired_salary_visible?/2` (the same viewer rule as
the status): `members` renders a quiet line under the status pill for signed-in
members (amount via `delimited_count`, currency **symbol**, translated period);
`everyone` also shows it logged-out and in the agent formats; `hidden` keeps it
off every rendering. The agent docs carry the same fact — the md/txt line via
`User.desired_salary_agent_line/1` (raw amount + currency **code** + period, so
it stays parseable), JSON/XML as a structured `{min, currency, period}` map — all
gated by the same predicate.

Both extras (availability visibility + the salary group) live in one
`[data-jobsearch-details]` panel on the Basics form that the `app.js` reveal
shows only once an employment status is chosen, so a member who stays "Not open
to work" sees one clean control. The salary amount is cleared by emptying the
field (validated `> 0`, so an empty value simply stores "no expectation").
Deliberately no notice-period / Kündigungsfrist field (#893): when someone
becomes available is a bilateral matter, not something the platform models.

## Job-search exclusion list / Ausschlussliste (issue #938)

The three-way visibility above is coarse: `everyone` shows the badge to your
own employer, `members` still shows any colleague with an account, and `hidden`
also hides it from the recruiters you *want*. The exclusion list is the "hide
from your employer" escape hatch — a per-member list of viewers who **never**
see the two job-search fields, subtracted as the **last step** of the gate.

**Data.** `viewer_exclusions` (schema `Vutuv.Accounts.ViewerExclusion`) is one
row per excluded target owned by `user_id`. Each row names exactly ONE target —
a member (`excluded_user_id`) or an email **domain** (`domain`, a bare lowercase
host) — enforced by a DB check constraint (`(excluded_user_id IS NOT NULL) <>
(domain IS NOT NULL)`) and the schema's two changesets; partial unique indexes
dedupe each kind per owner. Organizations (issue #929) can join later as a third
nullable target with no new table. It is a **general** per-member
viewer-exclusion list — currently only the job-search gate consults it, but
other visibility-gated fields can opt in later without a migration.

**The gate composes as `base AND NOT excluded`** (subtracting never adds):
`Vutuv.Accounts.job_search_visibility/2` resolves both fields for a viewer in
one query — it takes the #928 base predicates (`User.employment_status_visible?/2`
/ `User.desired_salary_visible?/2`) and ANDs in
`not viewer_excluded?/2`. `viewer_excluded?/2` (named generally, like the table
and CRUD, so a second gated field can consult the same list later) returns true when
the viewer is the excluded member, a **signed-in** viewer whose confirmed
email is at an excluded domain **or any subdomain of it** (host-suffix match,
`example.com` also matches `eu.example.com`; a signed-in member's email rows are
all confirmed — later addresses are PIN-verified before insert, the registration
address by the first login), **or a viewer the owner has blocked** (a full
`Social.block_user` implies this lighter visibility-only exclusion, so the owner
never keeps two lists for one person). A `nil` viewer (the anonymous public / crawler /
agent-format view) is **never** excluded and the owner never excludes their own
view, so the crawlable `.md`/`.txt`/`.json`/`.xml` formats stay exactly what the
base visibility says; only the signed-in `/api/2.0` read and the live profile
narrow. Both the profile LiveView (`@show_employment_status?` /
`@show_desired_salary?`, recomputed on the `{:job_search_visibility_changed, _}`
Activity event) and `VutuvWeb.AgentDocs.ProfileDoc` read the one
`job_search_visibility/2`, so HTML and agent formats can never disagree
(`agent_docs_drift_test.exs` covers the excluded-viewer case).

**Editor.** `/settings/job_search_exclusions` (`VutuvWeb.JobSearchExclusionsLive`,
linked from the Basics-form Jobsuche panel) adds a member by `@handle` or an
email domain and removes rows over the socket, each change broadcasting on the
owner's Activity topic so an excluded member's open profile drops the badge with
no reload. `Vutuv.Accounts` owns the CRUD (`add_excluded_member/2`,
`add_excluded_domain/2`, `remove_viewer_exclusion/2`, `list_viewer_exclusions/1`)
with a per-member cap (`viewer_exclusion_cap/0`), self-exclusion and duplicate
guards, and domain normalization (scheme/path/`@` stripped, lowercased). The
helper text is honest: excluding **reduces but cannot guarantee** — someone can
still look logged out, or from a private email.

## Profile job title chooser (issue #833)

The `Title @ Organization` line under a member's name is auto-picked from their
work experiences (`VutuvWeb.UserHelpers.current_job/1`: the first open-ended
dated role, else the most recent), but a member can **pin** which work
experience supplies it — an owner-only star toggle on the work-experiences
management page (`/:slug/work_experiences` → PUT/DELETE `…/:id/pin`, stored as
the nullable `users.profile_work_experience_id`), cleared back to automatic
anytime and nulled by the DB when the pinned role is deleted (`ON DELETE SET
NULL`).

The choice runs through the single `current_job` chokepoint, so it shows on the
profile header, every listing row, the meta description, JSON-LD and all agent
formats; with nothing pinned, behaviour is exactly as before.

## Work-experience CV categories (issue #840)

Every work experience carries a **category** (`work_experiences.kind`:
`employment` | `internship` | `volunteer`, default `employment`) so a CV
reader can tell a paid job from a Praktikum or an Ehrenamt. The member picks
it in a select on the entry form; every list rendering — the profile's
Experience card, the public `/:slug/work_experiences` page and the
`/settings/work_experiences` editor — splits into labeled groups
(Berufserfahrung, Praktika, "Ehrenamt, Hobby & Freiwilligenarbeit") via the
shared `WorkExperience.group_by_kind/1`, **but only once a non-employment entry
exists**: a jobs-only member keeps the familiar single unlabeled timeline.
The duration circles stay sized over the whole list, so a short internship
never rivals a decade-long job optically. The `volunteer` category is
deliberately broad (issue #916): its label names hobbies and Freiwilligenarbeit
alongside Ehrenamt, because unpaid community and hobby work (common in IT) is
often not recognized as volunteering. The labels live once in
`WorkExperienceHTML.kind_name/1` and `kind_label/1`.

The agent formats carry the category too (`kind` in the entry maps, a
`[Volunteering & hobbies]` / `[Internship]` note on the md/txt lines), as does
the GDPR export; the LinkedIn import maps `Volunteering.csv` into volunteer
entries.
The profile-job-title chooser is category-agnostic: the pin (and the automatic
heuristic) can select any entry, whatever its kind.

## Linking a work experience to an organization page (issue #931)

A work experience may **optionally** link to a [verified organization
page](organizations.md) via a nullable `work_experiences.organization_id`
(`ON DELETE SET NULL` — deleting an organization quietly unlinks, never cascades).
The link is a display convenience, **not** a badge: the employment claim stays
self-asserted, and the free-text `organization` column remains authoritative
for display whenever there is no link. vutuv never rewrites a member's own text.

**Editor UX.** The `/settings/work_experiences` form watches the organization
field: as the member types, `app.js` (`setupOrganizationLink`) queries
`GET /settings/work_experiences/organization_suggestions?q=…`
(`Organizations.suggest_organization_for_org/1` — an **exact**, case-insensitive match on
a verified organization's name or an alias, never a substring) and, on a hit, offers a
quiet one-line "Mit der Seite … verknüpfen?" the member accepts with one tap or
ignores. No match means no new UI. The choice rides in a hidden
`work_experience[organization_id]`; unlinking is one tap. It is a progressive
enhancement — the free-text field always works with JS off, and an already-linked
experience shows its linked state seeded from data attributes.

**The guard.** `WorkExperience.changeset/2` only ever links to a **verified**
(active, non-frozen) organization; a stale target (unknown, pending, frozen,
archived) is silently dropped back to nil rather than erroring (the member never
types the id, so a dead link falls back to the free text instead of blocking the
save). `Organizations.canonical_path/1` is the one definition of an organization's URL
(its root `/:handle` when claimed, else `/organizations/:slug`), shared by the
profile link, the agent docs and the sitemap.

**Display.** `WorkExperienceHTML.employer_name/1` renders a linked, active
organization as a small logo plus its **canonical name** linking to its page;
everything else (unlinked, or a **frozen/archived** organization — moderation must
never break a profile) renders the member's free-text organization exactly as
written. The block's organization is taken from its newest role
(`grouped_clusters/3` sets `:organization`). The agent formats carry the link too
(`SectionDocs.work_entry/1` adds a `organization: {name, url}` ref for a linked active
entry; the md/txt work lines show the name + URL), kept in sync by the drift
test. The reverse side — who works at an organization — is the organization page's People
section (see organizations.md).

## Education profile section

A member's schools sit in their own profile section (`Vutuv.Profiles.Education`,
`/:slug/educations`) alongside work experience — school, degree, field of study,
description and a start/end period, newest first.

It mirrors the work-experience section end to end: an Education card on the
profile, owner CRUD on the management page, and Markdown / plain text / JSON /
XML siblings under the same URL plus an extension (kept in sync by the
agent-docs drift test), plus a line in the GDPR data export.

Education entries carry a **category** too (issue #849, the twin of the
work-experience kinds above): `educations.kind` is `university` |
`apprenticeship` | `school`, default `university` (the correct reading of
nearly every pre-existing row on a professional network; the rest are one
edit away). Same mechanics as #840: a Kategorie select on the form, grouped
headings (Studium / Berufsausbildung / Schulbildung) on every list rendering
via `Education.group_by_kind/1`, shown only once a non-university entry
exists; `kind` rides along in the agent formats and the GDPR export. A
work-study program (duales Studium) or an apprenticeship's Berufsschule is
deliberately **not** a linked entity — members file an entry in each section;
revisit linking only if members ask.

## Telling followers about a new CV entry (issue #980)

The three CV sections — work experiences, education, certificates & licenses —
are the only parts of the profile that can announce themselves. Their
**new-entry** forms carry one checkbox ("Tell my N followers about this",
ticked by default, hidden while the member has no followers) which sets
`announce_to_followers?` on the row; the people who already follow them then see
one in-app notification linking to that entry. Adding several entries in one
sitting stays **one** notification: entries less than three hours apart are
grouped, so a CV overhaul never floods anyone's bell. Edit forms deliberately do not
offer it, and the flag is cast **only on insert**
(`Vutuv.Profiles.CvSection.cast_announcement/2`), so an edit can never
re-announce. No email is ever sent, and readers can switch the whole kind off in
their notification settings. The mechanics live in
[realtime.md](realtime.md#cv-updates-issue-980).

## Formatted descriptions (Markdown, issue #905)

A work-experience and an education `description` are **Markdown**, not a single
line of plain text: paragraphs and line breaks, bold / italic, bullet and
numbered lists, links, `@handle` / `#hashtag`. They render through the shared
`<.markdown_prose>` component (`VutuvWeb.UI`), which wraps
`VutuvWeb.Markdown.render/1` in the `.markdown markdown--post` body recipe — the
same sanitizing pipeline a post and the profile tagline use (raw HTML escaped,
images stripped, headings flattened to bold so a stray heading can't blow up a
compact timeline card). It renders on the public section pages
(`/:slug/work_experiences`, `/:slug/educations`) and the single-entry show
pages; the edit forms carry a "Markdown is supported" hint. The stored value is
unchanged plain Markdown source, so the agent-format siblings (`.md` is the
source verbatim, `.txt`/`.json`/`.xml` carry it too) need no change. Both
`description` columns are `text` with a `max: 10_000` validation (they legitimately
run long — see the LinkedIn-import note).

The CV document exports render the description per format (issue #920). The
HTML/print CV (`VutuvWeb.CV.Html`, what "Save as PDF" prints) runs the full
`VutuvWeb.Markdown` pipeline, with the relative `@handle`/`#hashtag` links
absolutized against `Endpoint.url()` so they work in a downloaded standalone
file. Word, OpenDocument and LaTeX share `VutuvWeb.CV.MarkdownBlocks`, which
reduces the Markdown to plain blocks — paragraphs with line breaks, bullet /
numbered lists (LaTeX gets real itemize/enumerate; docx/odt get "•"/"1."
prefixed paragraphs, since real Word lists would need a numbering part),
inline markers stripped to their text, a `[label](url)` link kept as
"label (url)" so the URL survives on paper. The JSON Resume `summary` keeps
the raw source (CommonMark by spec), and the CV builder's one-line entry
hints use `MarkdownBlocks.plain/1` so no literal `**markers**` show there.

## Languages profile section

Members list the **languages they speak** with a proficiency level (issue #865,
`Vutuv.Profiles.Language`, `/:slug/languages`). Each entry is a language plus a
level, displayed in the member's own order (issue #894) — see the reorder note
below.

The **language is stored as an ISO 639-1 code** (`"en"`, `"de"`) rather than a
free-text name: the data stays machine-readable (a BCP 47 primary subtag),
consistent across members, and localizable — `Vutuv.Languages` holds a curated
list of the world's most spoken languages and renders each name through Gettext,
so the same `"en"` reads "English" or "Englisch" depending on the viewer. The
member picks from a `<select>`; `Vutuv.Languages.known?/1` gates the changeset so
a stray code can never be stored, and a unique index on `(user_id,
language_code)` keeps a language from being listed twice.

The **proficiency** is `native` or a CEFR level (`a1`..`c2`). The badge shows the
compact form ("Native" / "B2"); the form and entry page show the descriptive
label ("Native speaker" / "B2 (Upper intermediate)"). Proficiency is shown per
entry but **no longer drives the sort**: `Language.ordered/1` delegates to
`Vutuv.Ordering.by_position/1`, so the member's own order wins (see below).

**Order is preference (issue #894).** Because a proficiency sort always floats a
member's mother tongue to the top, it cannot express "please write to me in my
second language". So languages joined the ordered sections: the member reorders
them by drag or arrows, and the **first entry is their preferred contact
language**. Once there is a choice (2+ languages) that first entry carries a
small "Preferred" marker on the profile card, the public section page and the
reorder tool, and the agent-doc siblings flag it too (md/txt gloss "(Preferred
contact language)", a `preferred: true` field in JSON/XML) so recruiters and
machines read the intent. The rule "the head of the ordered list, when 2+, is
preferred" lives in `VutuvWeb.AgentDocs.SectionDocs.language_entries/1` for the
docs and as a `first-of-2+` guard in the two profile templates. The
`add_position_to_languages` migration backfilled existing rows in the old
proficiency order, so no one's list reshuffled on deploy.

Like the other sections it has a profile card, owner CRUD on
`/settings/languages`, Markdown / plain text / JSON / XML siblings (kept in sync
by the agent-docs drift test), an `/api/2.0` read+write section, a line in the
GDPR export, and its own "Sprachen" section on the CV (issue #841, mapped to the
JSON Resume `languages` field). Linking a language to a specific work experience
or qualification is deliberately left out for now (revisit if members ask).

## Certificates & licenses profile section

Members list **certificates and licenses** (issue #859,
`Vutuv.Profiles.Qualification`, `/:slug/qualifications`): an AWS certification,
an Approbation, a Scrum Master badge — credentials with an issuer and, unlike a
degree, no school period and an **optional expiry**. Purely additive; it touches
nothing else. Each entry has a `name`, a `kind` (`certification` | `license`),
an `issuer`, an awarded and an optional expiry `year`/`month`, a `credential_id`,
and a display-only verification `url` (scheme-validated to http(s), **never
fetched server-side** — SSRF). A nullable `education_id` FK is reserved for issue
#857 (folding degrees into this table) and is always NULL today.

**Expired credentials are hidden from the public and shown to the owner.**
`Qualification.visible_to(owner?)` is the single SQL scope for this: the profile
preload (through `owner?`), the public `/:slug/qualifications` page, the CV and
the agent docs all compose it, so they hide the same lapsed entries; the owner's
own profile card and the `/settings/qualifications` editor show all of theirs and
mark the lapsed ones with an "Expired" badge (`Qualification.expired?/2`, the
per-entry twin of the scope — keep the two in sync). Entries display most
recently awarded first (`Qualification.ordered/1`).

The **profile card** carries an All / Certificates / Licenses tabber (a
`phx-click` filter on `UserProfileLive`, shown only when the member holds both
kinds); the public **section page** splits the same two kinds with
`group_by_kind` headings. Like the other sections it has owner CRUD on
`/settings/qualifications`, Markdown / plain text / JSON / XML siblings (kept in
sync by the agent-docs drift test), an `/api/2.0` read+write section, a line in
the GDPR export, and a "Zertifikate & Lizenzen" section on the CV (issue #841,
mapped to the JSON Resume `certificates` field).

The concrete win shipped day one: **LinkedIn's `Certifications.csv`** — read by
nobody and discarded on every import before this — now lands here. The importer
(`Vutuv.Imports.LinkedIn`) classifies the file, maps `Name`/`Authority`/`Started
On`/`Finished On`/`License Number`/`Url` to qualification fields, imports
everything as a certification (LinkedIn carries no licence/cert signal; the
preview tells the member to review), and dedups by name + issuer on re-import.

## Citing the credential a job was earned with (issue #858)

A work experience may **optionally** cite one of the member's own credentials
via a nullable `work_experiences.qualification_id` (`ON DELETE SET NULL` —
deleting the credential quietly unlinks, never cascades). The payoff is the
career-changer: a reader (or a recruiter's agent) can otherwise not tell which
credential backs which role, and two jobs may cite the **same** credential (a
locksmith's two roles, one Gesellenbrief). One primary credential per job; a
join table can come later if a real multi-credential need shows up.

The `/settings/work_experiences` form gains an optional "Qualification" select
(the member's own credentials as optgroups per kind, a "None" default) **only
when the member holds at least one credential** — the common credential-less
member sees the form unchanged. `WorkExperience.changeset/2` accepts only one
of the **owner's own** credentials: a foreign id is tampering (the form never
offers one) and errors, unlike the suggestion-fed organization link above,
which silently drops.

**Display.** `WorkExperienceHTML.qualification_line/1` is the one rendering of
the "Mit Qualifikation: …" line (naming and linking the credential), shared by
the profile Experience card, the section page and the entry show page. The
display policy lives in `WorkExperience.cited_qualification/1`: a lapsed
credential keeps showing on the jobs it earned (deliberately not scoped by
`Qualification.visible_to/2`), and every rendering surface preloads through
`WorkExperience.display_preloads/0`. The
agent formats carry it too (`SectionDocs.work_entry/1` adds a
`qualification: {id, name, kind}` ref; md/txt show a bracketed "With
qualification: …" note), kept honest by the drift test, and `/api/2.0` work
entries include the same ref. The CV exports fold the line into the entry's
description at one seam (`VutuvWeb.CV`), so every document format — including
JSON Resume, which has no native job↔credential field — carries it in the work
summary. The GDPR export names the cited credential per job. LinkedIn's
`Positions.csv` has no such link, so imported jobs arrive uncited.

**The reverse direction — usage badges on the credential (issue #1005).** Every
qualification list row (profile card, `/:slug/qualifications`, the
`/settings/qualifications` editor, all via the shared
`QualificationHTML.qualification_row/1`) shows how the member's jobs use the
credential: a brand-tint "Used for N jobs" pill plus either an emerald
"Currently in use" (some citing job is ongoing — no end year, the same
convention `CvSection.order_by_date/1` sorts by) or a slate "Last used: M/YYYY"
(the newest citing job's end). An uncited credential shows nothing — absence is
the "not used at all" signal, keeping rows calm. The policy lives in
`Qualification.job_usage/1`, reading the `work_experiences` preload spliced in
via `Qualification.citing_jobs_preload/0`; like `cited_qualification/1` it
falls through to nil on an unloaded association. The entry show page renders
the same facts as one "Jobs" line (`QualificationHTML.usage_line/1`), and the
agent formats carry a `jobs: {count, in_use, last_used}` map per entry
(`SectionDocs.qualification_entry/1`; md/txt append "used for N jobs ·
currently in use" to the facts line), kept honest by the drift test; `/api/2.0`
qualification entries include the same map.

## Qualification proof documents (the uploaded Nachweis)

A member may attach **one proof document** per certificate/license — a PDF or
an image of the credential — shown as a thumbnail on every qualification list
row and on the entry page, with a "Download original" link. Columns live on
`qualifications` (`document` = original client filename, `document_fingerprint`
= sha256[0..11] of the bytes, `document_content_type`, `document_size`,
`document_moderation`, `document_consented_at`).

**Consent is the gate.** The upload form carries an unticked "Show this file
publicly" checkbox spelling out that the file becomes publicly visible and
downloadable by anyone; `Qualification.changeset/2` (`cast_document/2`)
refuses the upload without it and records the consent timestamp. The document
columns are never mass-assignable — only a real `%Plug.Upload{}` plus consent
sets them, so the JSON API cannot smuggle them in.

**Storage** (`Vutuv.QualificationDocument`, proxy-served like post images — no
nginx changes): `qualification_documents/<id>/thumb.avif` + `document.<ext>`
(the public copy: PDFs verbatim, images re-encoded metadata-stripped so EXIF/
GPS never leaks), verbatim original + (for PDFs) the rendered first page
`scan_page.jpg` in the private `originals/` tree. PDF rendering shells out to
`pdftoppm`, capability-detected: without poppler-utils, `.pdf` leaves the
whitelist and the form says "please upload an image instead" (docs/ADMINS.md).
Files are written **after** the row commits (issue #776 ordering) and purged
on entry delete, document removal, moderation rejection and account deletion
(`Accounts.delete_user/1`); the regenerator covers the thumbs.

**Moderation**: kind `qualification_document` in the AI image scan (the
review-cover pattern — no quarantine tree, the authorizing proxy
`VutuvWeb.QualificationDocumentController` checks `document_moderation`).
Pending documents are owner-only (amber "Wird geprüft" pill); the scan source
is the rendered PDF page or the original image, fingerprint-guarded. The proxy
URLs carry the fingerprint (`document/thumb-<fp>.avif`, `document/<fp>.<ext>`)
so they are immutable and cacheable; a re-upload changes them. `?dl=1`
switches to an attachment download named after the member's original filename.

**Docs**: `SectionDocs.qualification_entry/2` carries a released document as
`document: {url, content_type, size}` (nil while pending — the agent docs are
the anonymous public view); md/txt append a "proof document" link,
drift-checked. The external `url` "Proof" link (a verification URL) stays a
separate, complementary field.

## Online messengers profile section

Members list the online messengers they can be reached on (`Vutuv.Profiles.Messenger`,
issue #949): Signal, WhatsApp, Telegram, Threema, Matrix and Session. This is a
distinct resource from social media accounts, because a messenger contact is a
direct line to reach someone, not a public profile to browse, and its address is
usually **not** a phone number.

Each entry is a `provider` + `value`. The provider knows the shape of its value
and how to turn it into a **deep link** that opens the app straight at that
contact (`Messenger.url/1`): `wa.me/<digits>`, `signal.me/#p/<+E164>`,
`t.me/<name>`, `threema.id/<id>`, `matrix.to/#/<@user:server>`.

**Signal and WhatsApp accept either a phone number or a username** (both services
offer usernames now). A phone-shaped value (letter-free) is validated and
canonicalised through the very same `Vutuv.Phone` validator the phone-numbers
section uses, so a typed number becomes `+country` format and junk is rejected; a
username (it always contains a letter) is kept as typed, so a valid handle is
never wrongly rejected as "not a phone number". A phone value gets the
`wa.me`/`signal.me` deep link; a Signal/WhatsApp username has no public web
resolver, so it shows the bare handle (copyable), the same as Session. The other
providers carry a service-specific id/username with its own format check.

Like the other sections it has a Messengers card on the profile, owner CRUD on
`/settings/messengers` (public showcase at `/:slug/messengers`), an ordered
`position` (see below), agent-format siblings (`SectionDocs.messenger_entry/1`,
kept in sync by the agent-docs drift test) carrying the deep link, `IMPP` lines
on the vCard (RFC 4770), and an `/api/2.0` read+write section.

## Tags and their endorsements (issue #895)

The profile's **Tags** card is a row of `<.tag_vote>` chips: the tag name, the
visible-endorsement count as a pill (which is also the endorse toggle for a
logged-in non-owner) and, on hover, a small roster naming the endorsers. A hover
is not available on a touch device, so the chip alone leaves the endorsements
half-hidden.

The section page **`/:slug/tags`** is where they are readable outright. It is a
row per tag: the name (plus the `<.honor_tag_badge>` for an honor tag) on the
left, and on the right the `<.endorsed_by>` line — an `<.avatar_stack>` of up to
five endorser faces beside a sentence naming the newest of them ("Endorsed by
Alex Demushkane and 19 others"), the sentence linking to that tag's full
endorser list at `/:slug/tags/:tag/endorsers`. It stays the plain public
showcase every section page is: viewer-independent, **no** endorse control (that
lives on the profile), nothing for an honor tag, which is an admin-granted badge
rather than a peer vouch, and nothing at all for a tag nobody has endorsed yet.
The controller preloads the endorsements with their endorsers
(`UserTagEndorsement.visible_with_endorser/0`, so a hidden or unconfirmed
account neither shows nor counts, issue #783), which is also what feeds the
`endorsers` list the agent-format siblings carry per entry
(`SectionDocs.index_entries/2`; the profile doc's tag list keeps the plain
count).

Because that page shows more than the card does rather than just more of it, the
profile's Tags card always offers a visitor the "All tags" footer link — not
only once the card is truncated, which with the 15-tag cap it never is. The
owner's footer stays the "Manage" bridge into `/settings/tags`.

## Ordered profile sections

Members arrange their links, phone numbers, addresses, social media accounts,
messengers, email addresses and languages in the order they want instead of by
creation date (a nullable `position` column per table, backfilled in creation
order — except languages, backfilled in their old proficiency order; the shared
`Vutuv.Ordering` context owns the bookkeeping). For languages the order
additionally **means preference** (issue #894, the first is the preferred contact
language); for the others it is purely presentational.

Each management page (`/settings/links`, `/phone_numbers`, `/addresses`,
`/social_media_accounts`, `/messengers`, `/emails`, `/languages`) carries an
owner-only ordering tool, the embedded `VutuvWeb.SectionReorderLive` (rendered with `live_render`,
like the app shell): drag an entry by its handle, or use the per-row up/down
arrows. Most sections key their per-row edit/delete routes on the row id;
languages address entries by their ISO code (`Phoenix.Param`), which is why
`SectionReorderLive`'s `edit_path`/`entry_path` take the whole entry.

Both persist over the LiveView socket with **no page reload** (the `Reorder` JS
hook does the drag; the arrows are `phx-click`), and the arrow reorders glide
into place with a small FLIP animation (~180ms, disabled under
`prefers-reduced-motion`); the tool is mobile-first, so on touch — where native
drag is unavailable — the comfortably-sized arrows are the reorder path.

Every change renumbers positions 1..n server-side, scoped to the owner.

The chosen order drives the profile preview, the section page and every
agent-format sibling; new entries append to the end.

## Verified webpage links (`Vutuv.Profiles.LinkVerification`)

A member can prove a profile **Link** is really their own webpage; it then earns
a small emerald ✓ (`<.verified_mark>`) next to it on the profile Links card, the
`/:slug/links` pages and the agent-format siblings (`SectionDocs.link_entry/1`
carries `verified`; md/text render "(verified webpage)"). This is the people-side
twin of verified organization pages, and shares the same proof mechanics
(`Vutuv.WebVerification`; see `organizations.md`).

Three methods, the member's choice on the owner-only page at
`/settings/links/:id/verify` (each a small `<.verify_form>` posting its method):

- **Back-link (rel=me)** — the default. The member adds a link back to their
  profile marked `rel="me"` on the page; the verifier fetches the page (SSRF-
  guarded, no redirects, size-capped) and scans for an `<a>`/`<link>` whose `rel`
  contains `me` and whose `href` resolves to the member's canonical profile URL
  (derived from `Endpoint.url()`, installability-safe). No token — the back-link
  target is the proof. Works on any page the member can edit, including shared
  hosting (a blog, a `github.io` page, a hosted portfolio); it is the IndieWeb /
  Mastodon standard, completing the loop vutuv already half-emits (`rel="me"` in
  the profile head and on social chips).
- **DNS / well-known** — the same proof mechanism organizations use, for a member
  who controls the whole host, using a per-link `verification_token`. Links use
  their own scheme (`vutuv-verify=` TXT / `/.well-known/vutuv-verify.txt`),
  distinct from the organization `vutuv-organization-verify=` scheme, so a link proof
  never doubles as an organization proof on the same host. The DNS TXT record is
  accepted on either the host itself **or** the CNAME-safe `_vutuv.<host>`
  alternate name (`WebVerification.dns_challenge_name/1`): a host that is itself a
  CNAME (a hosted changelog, a redirect) cannot carry a bare-host TXT record — a
  CNAME and a TXT cannot coexist on one name (RFC 1034) — so the underscore label
  (the `_dmarc` / `_acme-challenge` convention, RFC 8552, never a CNAME target)
  gives such a member a place to publish it (issue #947).

State lives on the `urls` row (`verification_method`, `verification_token`,
`verified_at`, `last_checked_at`, `grace_deadline_at`) — per-link and independent,
with **no** uniqueness constraint (unlike organization domains: two members may each
prove the same shared host by their own proof, and rel=me is member-specific).
Editing a link to a different URL clears its mark (`Url.changeset/2`). Verified
links are re-checked hourly (`Vutuv.Profiles.LinkRecheckSweeper` →
`recheck_due_links/0`) with a 7-day grace window before the mark drops, mirroring
the organization domain re-check.

Gated by `config :vutuv, :verify_user_links` (env `VERIFY_USER_LINKS`, default
on). Off = disabled on the installation (no outbound calls); existing marks keep
working, no new link can be verified. Tests stub DNS / HTTP via
`:user_links_dns_resolver` / `:user_links_req_options`.

## Email & phone number types, addresses and maps

Every email address and phone number carries an owner-editable type label.
Emails are **Work / Personal / Other** (`Vutuv.Accounts.Email.email_type`,
default `Other`; offered on the registration form and the add-email form, the
add-email choice carried through the two-step PIN confirmation via the session,
editable later on the email edit form), phone numbers **Work / Cell / Home /
Fax**.

The label shows on the profile contact card and the management/show pages, is
exported in the vCard (`EMAIL;TYPE=` / `TEL;TYPE=`) and the GDPR JSON, and rides
in the agent-format docs — giving an email a type changed an email entry from a
bare address string to a `{id, type, value}` map (matching phone numbers), a
breaking change that bumped the agent-doc `schema_version`.

On the profile contact card, German numbers are shown to **German viewers** in
national format (`+49 261 9886803` → `0261 9886803`) while every `tel:` link
keeps the canonical E.164 form, via `Vutuv.Phone` (the
`ex_phone_number`/libphonenumber port). Every other displayed number keeps its
international `+country` prefix but is **grouped with spaces**
(`+447840875616` → `+44 7840 875616`) so it reads cleanly instead of running
together; the country code is never stripped. The locale-aware rendering is
`Vutuv.Phone.national/2`; the section/show pages and the agent-doc siblings use
the locale-independent `Vutuv.Phone.display/1`, which applies the same
international grouping (and re-spaces a legacy value stored without spaces). An
unparseable or invalid value falls back to the stored text unchanged.

Whenever a number is displayed **with** its international `+…` prefix, the card
shows the calling code's country **flag** before it, with a `+49 is the calling
code of DE`-style tooltip naming the calling code and its ISO region (issue
#892). `Vutuv.Phone.country_flag/2` gates on the same national/2 seam — a German
number in national form (no `+` prefix) gets no flag — resolves the ISO region
via libphonenumber and turns it into the flag emoji through `Vutuv.Cldr.Territory`
(`ex_cldr_territories`). That CLDR data is **compiled in**, so no runtime network
is needed; the backend `Vutuv.Cldr` carries only the `Cldr.Territory` provider,
which keeps it safe for air-gapped intranet installs.

On the way **in**, the changeset (`Vutuv.Phone.normalize/1`) parses a typed
number against the default `DE` region, rejects anything libphonenumber does not
recognise as a *valid* number (so only real numbers are saved), and stores the
rest in canonical international form (`0261-123456` → `+49 261 123456`); a
foreign number keeps its own country code.

**Addresses** follow the same German-viewer rule (`Vutuv.Address`): a German
viewer (`locale == "de"`) looking at a German address sees no redundant
"Deutschland" line, while foreign addresses and non-German viewers keep the
country; every address on the profile card also links out to the major map
services — **Google Maps, OpenStreetMap and Apple Maps** — and each logged-in
member chooses on the account settings hub which of those to show and which is
the default (rendered as the primary "Open in …" button, the rest a quiet "Also
on" line); opening a non-default service promotes it to the new default live
across the page and persists it (`Vutuv.Maps`; with JS off they stay plain links
that still open).

A logged-out visitor sees the default set (Google primary).

The geocoding query keeps the country even when it is hidden on screen

## Inline Mastodon + Bluesky feed

A profile that lists Mastodon or Bluesky accounts gets a **"Social media posts"
card** (`Vutuv.SocialFeed`, with the per-network clients `Vutuv.Mastodon` and
`Vutuv.Bluesky`): the three latest public posts of *every* listed account,
merged newest-first into one feed, each row rendered like a vutuv post (avatar +
display name + Berlin-time stamp) minus the action bar, with the whole row
clicking through to the original post on its home network.

Bodies run through the member-post Markdown pipeline — URLs autolink,
`#hashtags` link to vutuv tag pages through the usual non-empty-tag gate, while
`@mentions` deliberately stay plain (they name remote accounts, not vutuv
members).

The avatar is fetched server-side and embedded as a data URI and Mastodon's post
HTML is reduced to sanitized text first, so a visitor's browser never contacts
the remote network.

Fetching happens from the network's public API after the page connects (Mastodon
asks the account's own instance, Bluesky the central `public.api.bsky.app`
AppView; a Bluesky account that hides from logged-out visitors via
`!no-unauthenticated` shows nothing; a small spinner on the account row shows
while a feed loads; the SEO/agent renders never include the posts) and is cached
for 15 minutes with single-flight deduplication (many simultaneous visitors
cause one fetch).

Struggling servers are backed off in escalating steps (15 min up to 48 h,
persisted across deploys) and a dead account (or an exhausted ladder) is
deactivated for good until the member re-saves the handle; members switch the
whole card off on the Privacy settings page (`show_mastodon_feed?`, which
predates Bluesky and gates both networks).

## Code-forge statistics ("Code" card, issue #922)

A profile that lists a **GitHub, GitLab or Codeberg** account gets a **"Code"
card** (`Vutuv.CodeStats`, per-forge clients `Vutuv.CodeStats.GitHub` /
`GitLab` / `Codeberg`): neutral public facts per account — total stars,
repository count, followers, "member since", most-used languages (rendered
as calm slate pills, deliberately not the brand tag chips — they are not
endorsable) and the top three repositories — no score, no rating. A "Last
active" date appears only once the account has been quiet for over four
weeks (`CodeStats.dormant_since/1`, mirrored in the md/txt formats): it is
a dormancy signal, not a live ticker — JSON/XML always carry the raw
`last_active_at`.

Unlike the social feed the **database is the cache**: each fetch (2–3 API
requests) writes a provider-neutral snapshot map onto the account's
`social_media_accounts` row (`code_stats` + `code_stats_fetched_at`,
aggregated by `Vutuv.CodeStats.Snapshot`), so rendering never touches the
network and the card appears in the crawler-visible disconnected HTML **and
the agent formats** (the profile's md/txt/json/xml carry a `code_stats`
section — kept in sync by the drift tests). A snapshot serves for **7 days**;
the first fetch runs in the background right after the account is created
(or its handle edited), later refreshes are triggered by profile views that
find the snapshot stale. `Vutuv.CodeStats.Fetcher` single-flights the
background fetches, and an open profile LiveView re-renders the card when
the fresh snapshot lands (`{:code_stats_updated, account_id}` on the owner's
Activity topic).

Failures reuse the social feed's persisted backoff ladder / deactivation
columns (the provider sets are disjoint). The whole feature sits behind the
`:fetch_code_stats` flag (off = plain links, for intranet installations);
members opt out per profile on the Privacy settings page
(`show_code_stats?`). GitHub's unauthenticated rate limit (60 requests/hour
per IP) is enough at the 7-day cadence; the optional `GITHUB_API_TOKEN` env
var raises it to 5,000/hour and can be added to a running installation at
any time (see `docs/ADMINS.md`).
