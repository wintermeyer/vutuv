# Verified organization pages

Organization pages live at `/organizations/:slug`, with a public directory at
`/organizations`. The defining rule (issue #929): **an organization page can only exist
once someone proves control of the organization's web domain.** There are no
unverified pages, which kills the "first user creates a typo'd organization name"
foot-gun at the root.

Context: `Vutuv.Organizations`. Schemas under `lib/vutuv/organizations/`.

## Kind (`organizations.kind`, Art)

An organization is **not** necessarily a company: a Verein, a Behörde, the UN or
the Bundestag are organizations too. `organizations.kind` is a required
`Ecto.Enum` chosen in the claim wizard, in this order: `company`, `association`,
`government`, `education`, `ngo`, `other`. The label (a Verein reads "Verein /
Verband", a Behörde "Behörde / Öffentlich") is the single source
`Organization.kind_label/1`, shared by the wizard's `<.kind_select>`, the page and
directory `<.kind_badge>` and the agent docs, so they can never disagree.
`Organization.schema_org_type/1` maps the kind to a schema.org `@type` for the
JSON-LD (a company is a `Corporation`, a Behörde a `GovernmentOrganization`, a
university an `EducationalOrganization`, everything else a plain `Organization`).
The DB column defaults to `"company"` only to backfill the rows that predate the
field; new pages must actively choose (a blank submit fails the cast).

## Root handle (`organizations.username`, #941)

An organization can opt in to a member-style `@handle` and become reachable at the URL
root, `/:handle`, exactly like a personal profile (`/lufthansa` alongside
`/wintermeyer`). The handle namespace is **shared** with members: a handle is
unique across `users.username` **and** `organizations.username`. Because Postgres
cannot span a unique constraint over two tables, that guarantee lives in one
registry table, `handles` (`Vutuv.Accounts.Handle`, context `Vutuv.Handles`):
one row per taken handle, `UNIQUE(value)`, owned by a member XOR an organization
(`(user_id IS NOT NULL) <> (organization_id IS NOT NULL)`, per-owner partial-unique
indexes, both FKs `ON DELETE CASCADE`). Every handle write — a member's
`username_changeset` (register / rename), an organization's `Organizations.claim_handle/2`
— upserts its registry row **in the same transaction** as the owner write
(`Vutuv.Handles.put_user_handle/2` / `put_organization_handle/2`), so a colliding
claim loses on the unique index instead of racing. Resolution itself reads the
owner tables directly and never touches `handles`; the registry is purely the
write-time uniqueness lock. `Vutuv.Handles.validate_handle/2` is the single
grammar definition (Twitter style `^[a-z0-9_]+$`, 3-15, lowercased, never a
`ReservedSlugs` word), shared by both owner changesets.

Claiming is owner-only, on the organization **edit** page (`OrganizationLive.Edit`,
"Root handle" card). It is opt-in and first-come-first-served across the shared
namespace; an organization without a handle is unchanged (reachable only at
`/organizations/:slug`).

The same edit page has an owner-only **Danger zone** with a permanent
**Delete this organization** action (confirm-gated, `owner?`-only, re-checked in the
handler because a non-owner admin can also reach the edit page): it runs the
`delete_organization/1` chokepoint (cascades domains / roles / aliases / images /
likes / bookmarks / the `handles` row, settles any moderation case, purges the
on-disk image files) and so frees the organization's verified domains **and** its
`@handle` for re-claim. Site admins keep delete plus the reversible
`archive_organization/1` (soft "archived" status) in `/admin/organizations`; owners have
only the hard delete.

**Resolution + canonical.** The root `/:slug` resolver
(`VutuvWeb.Plug.UserResolveSlug`, `dispatch_organization: true` on the bare profile
route only) keeps the member fast path (`users.username`), and on a miss renders
the matching organization's page in place via `OrganizationController.render_page/2`. So a
handled organization serves at **both** `/:handle` and `/organizations/:slug` (200), with
the root URL as **canonical**: `render_page/2` sets the `:canonical_url` assign
(honored by `OpenGraph.canonical_url/1`) so `/organizations/:slug` carries
`rel="canonical"` → `/:handle`; the sitemap (`Vutuv.Sitemap.organization_entries/1`)
and the agent-doc self-links (`OrganizationDoc`) list the root URL too. Member-only
sub-pages (`/:slug/followers`, ...) never dispatch to an organization (the
`:user_pipe` uses the resolver without the option), so an organization handle 404s
there. Rollout was one additive, N-1-safe deploy (new table + backfill of every
member's handle + nullable `organizations.username`).

## Trust model

Edit rights over a page come **only** from proving control of the domain, never
from a self-asserted employment claim. Two proof methods, both proving control
of the domain itself. The proof mechanics live in the shared
`Vutuv.WebVerification` (also used by verified personal-webpage links — see
`profiles.md`); `Vutuv.Organizations.Verification` is the organization-flavoured wrapper
that owns the organization gate and test seams:

- **DNS** — a `vutuv-organization-verify=<token>` TXT record on the domain.
- **Website file** — the token served at
  `https://<domain>/.well-known/vutuv-organization-verify.txt`, fetched with `Req`
  behind the SSRF guard (`Vutuv.Ssrf`), never following redirects.

The organization scheme (`vutuv-organization-verify=` / `/.well-known/vutuv-organization-verify.txt`)
is deliberately distinct from the `vutuv-verify=` scheme personal-webpage links
use (see `profiles.md`), so proving a link never doubles as proving an organization on
the same host, and a domain owner can hold both proofs at once via one DNS zone
or two separate well-known files.

There is deliberately **no e-mail method**. An address like `…@gmail.com` proves
control of a *mailbox*, not of the *domain*, so anyone with a Gmail account
could otherwise claim the gmail.com page. DNS and the well-known file both prove
control of the domain.

Both methods are network calls, so they are gated by
`config :vutuv, :verify_organization_domains` (env `VERIFY_ORGANIZATION_DOMAINS`, default
on). Off = organization domain verification is disabled on the installation (no
outbound calls); existing verified pages keep working, but no new page can be
created.

Domain identity is the **exact host**: `sub.example.com` and `example.com` are
distinct, so a subsidiary or brand with its own (sub)domain can verify its own
page even when the parent's domain is already claimed. No public-suffix list.
The `organization_domains.domain` column is `UNIQUE` across the table — the
anti-squatting anchor: one verified domain belongs to exactly one organization. One
organization may hold several verified domains (multi-TLD setups, a rebrand keeping
the old domain); exactly one is `primary?` (a partial unique index enforces it),
and the public page shows "Verifiziert über *organization.tld*" with that primary
domain — the domain, not the name, is what viewers trust.

## Lifecycle

`organizations.status`: `pending` → `active` → (`frozen` | `archived`).

- The claim wizard (`/organizations/new`, logged-in email-confirmed members) creates
  a `pending` organization plus an owner `OrganizationRole` and an unverified primary
  `OrganizationDomain` derived from the website URL.
- The owner finishes the claim on the page's verification panel (shown to the
  owner while the page is `pending`): publish the record/file, click **Verify
  now**. A successful proof stamps `verified_at`, flips the page to `active`, and
  sends an operator notice (`Emailer.organization_verified_notice/2`) so a human
  reviews every new page while volume is low.
- DNS / well-known domains are **re-checked weekly**
  (`Vutuv.Organizations.DomainRecheckSweeper`, gated by
  `:recheck_organization_domains`; the sweeper ticks hourly but only re-checks
  domains whose last check is older than the weekly interval, spreading the load
  rather than bursting it). A domain whose record/file has vanished enters a
  grace window (`grace_deadline_at`, 7 days); once it passes, the domain loses
  verified status, and if it was the organization's last verified domain the page
  falls back to `pending` and the operator is alerted
  (`Emailer.organization_unverified_notice/2`).

## Team roles (`organization_roles`, #930)

A page is run by a team, not just its claimant. Each `OrganizationRole` grants a
proof-derived **power**, never an employment claim:

- **owner** — everything: roles, domains, the page + aliases, and (from issue 5)
  job postings.
- **admin** — the page + aliases and job postings, but not roles or domains.
- **recruiter** — job postings only.

The predicates live in `Vutuv.Organizations`: `owner?/2`, `can_edit_page?/2`
(owner ∪ admin), `can_manage_roles?/2` and `can_manage_domains?/2` (owner). The
older `can_manage?/2` is the *staff* predicate (creator ∪ any role holder) used
for **visibility** — a recruiter still sees a pending/frozen page — not for
writes.

Invariant: **every organization keeps ≥ 1 owner.** `remove_role/1` and `update_role/3`
refuse to remove or demote the last owner (`{:error, :last_owner}`), exactly like
the last-domain rule. A grant is a notification: the `organization_roles` row is a
source of the derived notification feed (`Vutuv.Activity.organization_role_items/3`,
self-grants excluded so the claim wizard's owner row is not "news"), and
`Activity.notify_organization_role/4` pushes the live badge/toast at grant time. The
owner-only roster lives at `/organizations/:slug/roles`
(`VutuvWeb.OrganizationLive.Roles`, add by `@handle`/email with a live typeahead
`Organizations.suggest_members/2`).

## Multi-domain management (`/organizations/:slug/domains`, #930)

An organization may prove several domains. Exactly one is `primary?` (the partial
unique index enforces it); it is the one shown in the "Verifiziert über …"
badge. `Organizations.add_domain/3` creates a further **non-primary, unverified**
`OrganizationDomain`; the owner finishes it with the same #929 wizard on the domains
page, which flips it to verified without touching the (already active) organization
status. `set_primary_domain/2` only accepts a verified domain and flips
atomically (old primary off, then new on, so the one-primary index is never
violated mid-write). `remove_domain/2` refuses the **last verified** domain
(`{:error, :last_domain}`) and, when it removes the primary, auto-promotes the
oldest remaining verified domain so the badge follows. The periodic re-check
(`DomainRecheckSweeper`) drops a failing **non-last** domain with an operator
alert (`Emailer.organization_domain_dropped_notice/2`); only losing the **last**
verified domain sends the page back to `pending`.

## Aliases (`organization_names`, #930)

Alternative names an organization is findable under (solves #851): an organization that
trades under several names — its registered name vs. a product brand — is found
under all of them, because the directory and admin search match names **and**
aliases (`Organizations.name_or_city_ilike/2` adds an `EXISTS` over `organization_names`).
`kind` is `alias | former | brand | abbreviation`. A **rename** auto-appends the
old name as a `former` alias (`update_organization/2` in an `Ecto.Multi`), so the
rename history is data, not a log file; the slug never changes, so old URLs keep
resolving. Aliases join the page's agent formats (`.md`/`.txt` "Also known as"
line, `.json`/`.xml` `aliases` list — `OrganizationDoc.build_show/3`) and the public
page's "Also known as" card, and are edited by owner/admin on
`/organizations/:slug/edit`.

**Collision guardrail:** an alias equal (case-insensitive) to another *verified*
organization's name or alias is stored but stamped `flagged_at` for the admin queue
(`Organizations.add_alias/3`) — there is deliberately **no** user-facing warning or
confirmation. Identical organization names are common and legitimate (many unrelated
"Müller GmbH"s), so a warning would imply wrongdoing in the normal case and, in
the abuse case, only tip off a squatter; a human reviews every flag quietly on
`/admin/organizations`.

## Machine visibility

Two owner toggles, same semantics as a member's `noindex?`/`noai?`:

- `seo?` (default on) — off ⇒ `noindex`, no `Organization` JSON-LD, out of the
  sitemap.
- `geo?` (default on) — off ⇒ the `.md`/`.txt`/`.json`/`.xml` siblings 404 and
  the page leaves `/llms.txt` and the directory's agent-format listings.

Only an active, non-frozen page serves agent formats, and only for a viewer who
is not the owner does the anonymous doc render (a `.md` URL never serves HTML;
pending/frozen/archived pages 404 their siblings for everyone, cache-safe like a
hidden profile). See `VutuvWeb.AgentDocs.OrganizationDoc` and
`agents-and-seo.md`.

## People (issue #931)

The organization page shows a **People** section: members whose work experience is
[linked to this organization](profiles.md#linking-a-work-experience-to-a-organization-page-issue-931).
Current members (an ongoing linked role, no end date) lead; past members follow,
tagged "Ehemalig". Each row is the member's avatar + name (a crawlable
`<a href>` to their profile) plus the linked role's title **exactly as they wrote
it** — titles stay the member's own words, never normalized. The list is
offset-paginated (`Organizations.organization_people_page/2`, a "Load more" over the
socket); `Organizations.organization_people_count/1` is the formatted total.

Privacy is the **member-directory gate**: only members in
`Vutuv.Directory.indexable_users` semantics (confirmed, not search-opted-out, not
moderation-hidden) appear, to every viewer — so a member who opted out of public
listing is never surfaced through an organization page either. The same gate feeds the
agent-format people list (`OrganizationDoc` → md/txt/json/xml), kept in sync by the
drift test. The People section gives organization pages real crawlable substance and
internal links to profiles (both help ranking).

## Engagement

Like + bookmark reuse the shared `Vutuv.Engagement` insert kernel. Like counts
are public and live over PubSub (topic `"organization:<id>"`, `compact_count`);
bookmarks are private and listed under the member's `/bookmarks` hub (a
Organizations sub-tab). Both cascade on organization or user deletion.

## Moderation

The report → freeze → case machinery (`Vutuv.Moderation`, see
`moderation.md`) is extended with the content type `organization`. A first report
never freezes a verified page; it lands in the admin queue (profile-case
style). A second trusted reporter, or the spam threshold, freezes the page:
frozen pages vanish for the public but stay visible to the owner + admins behind
the owner banner. Reporting an organization does **not** sever the reporter's personal
ties to whoever claimed it. The strike ladder lands on the owning member.

## Images

The logo is a `OrganizationImage` (the `post_images` pattern) served through the
authorizing proxy `/organization_images/:token/:version` (`Vutuv.OrganizationImageStore`,
`VutuvWeb.OrganizationImageController`), so a pending/frozen page's logo is
owner/admin-only. A page with no logo renders an initials tile. `organization_images`
rows survive their uploader deleting their account (`user_id` nilifies), so a
logo never breaks. The description is untrusted Markdown, rendered like posts
(`VutuvWeb.Markdown`, images stripped).

## Structured location

`country` is stored as an ISO 3166-1 alpha-2 code (`Vutuv.Countries`, the shared
controlled-vocabulary helper) and rendered localized (German/English), because
it is a filter key and a JSON-LD value — unlike the legacy `addresses` table,
which stores display names. **City and country are required** at claim time (they
are the filter keys and the `addressLocality`/`addressCountry` of the
`Organization` JSON-LD `PostalAddress`); **street address and postal code are
optional**, because some countries have no postal-code system at all (Ireland
pre-Eircode, the UAE, Hong Kong, …) and not every operator wants to publish a
street. The address rendering (page + agent docs) and the JSON-LD both fold away
whichever parts are missing, so a city-and-country-only address renders cleanly.
