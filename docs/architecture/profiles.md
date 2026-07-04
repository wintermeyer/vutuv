# Profiles

What a member's profile shows and where the data comes from. The profile page
itself is a LiveView ([realtime.md](realtime.md)), every public profile page
has agent-format siblings ([agents-and-seo.md](agents-and-seo.md)), and
members edit all of it from the settings hub
([settings-and-account.md](settings-and-account.md)).

## Profile "view as" preview

On your own profile a slim "Ansehen als" switcher re-renders the page as `Sie`
(your full view) or `Öffentlich` (logged-out visitors and search engines).

The public preview drops the owner chrome and enforces post visibility
**server-side** via `?view_as=public` (`Vutuv.Posts.scope_visible_preview/2`),
so restricted content never reaches the preview HTML.

Honored only for the owner; a stranger's `?view_as=` is ignored.

The profile-section pages no longer carry the switcher: `/:slug/<section>` IS
the public view for everyone, and editing happens at `/settings/<section>`.

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
(Berufserfahrung, Praktika, Ehrenämter) via the shared
`WorkExperience.group_by_kind/1`, **but only once a non-employment entry
exists**: a jobs-only member keeps the familiar single unlabeled timeline.
The duration circles stay sized over the whole list, so a short internship
never rivals a decade-long job optically.

The agent formats carry the category too (`kind` in the entry maps, a
`[Volunteering]` / `[Internship]` note on the md/txt lines), as does the GDPR
export; the LinkedIn import maps `Volunteering.csv` into volunteer entries.
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

## Ordered profile sections

Members arrange their links, phone numbers, addresses, social media accounts and
email addresses in the order they want instead of by creation date (a nullable
`position` column per table, backfilled in creation order; the shared
`Vutuv.Ordering` context owns the bookkeeping).

Each management page (`/:slug/links`, `/phone_numbers`, `/addresses`,
`/social_media_accounts`, `/emails`) carries an owner-only ordering tool, the
embedded `VutuvWeb.SectionReorderLive` (rendered with `live_render`, like the
app shell): drag an entry by its handle, or use the per-row up/down arrows.

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
`ex_phone_number`/libphonenumber port); foreign numbers and non-German viewers
see the stored value unchanged.

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
