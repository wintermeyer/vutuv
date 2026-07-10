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

The rule lives in one seam, `User.employment_status_visible?/2` (returns false
when no status is set, so a call site gates the whole badge row on it). The
profile template passes the viewer (`@current_user`); `ProfileDoc` passes its
`:viewer` — `nil` for the anonymous extension URLs (so `"members"`/`"hidden"`
drop out), the token's member for an authenticated `/api/2.0` read (so a
`"members"` status shows there). Because the profile is a LiveView, changing the
setting in `/settings/profile` reflects on an open profile without a reload.

The Basics form reveals the visibility select only once a status is chosen (the
`EmploymentVisibility` enhancement in `app.js` toggles a server-rendered
`hidden` on the sub-field), so a member who stays "Not open to work" sees one
clean control. Deliberately no notice-period / Kündigungsfrist field (#893):
when someone becomes available is a bilateral matter, not something the platform
models.

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

## Ordered profile sections

Members arrange their links, phone numbers, addresses, social media accounts,
email addresses and languages in the order they want instead of by creation date
(a nullable `position` column per table, backfilled in creation order — except
languages, backfilled in their old proficiency order; the shared `Vutuv.Ordering`
context owns the bookkeeping). For languages the order additionally **means
preference** (issue #894, the first is the preferred contact language); for the
others it is purely presentational.

Each management page (`/settings/links`, `/phone_numbers`, `/addresses`,
`/social_media_accounts`, `/emails`, `/languages`) carries an owner-only ordering
tool, the embedded `VutuvWeb.SectionReorderLive` (rendered with `live_render`,
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
