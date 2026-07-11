# Verified company pages

Company pages live at `/companies/:slug`, with a public directory at
`/companies`. The defining rule (issue #929): **a company page can only exist
once someone proves control of the company's web domain.** There are no
unverified pages, which kills the "first user creates a typo'd company name"
foot-gun at the root.

Context: `Vutuv.Companies`. Schemas under `lib/vutuv/companies/`.

## Root handle (`companies.username`, #941)

A company can opt in to a member-style `@handle` and become reachable at the URL
root, `/:handle`, exactly like a personal profile (`/lufthansa` alongside
`/wintermeyer`). The handle namespace is **shared** with members: a handle is
unique across `users.username` **and** `companies.username`. Because Postgres
cannot span a unique constraint over two tables, that guarantee lives in one
registry table, `handles` (`Vutuv.Accounts.Handle`, context `Vutuv.Handles`):
one row per taken handle, `UNIQUE(value)`, owned by a member XOR a company
(`(user_id IS NOT NULL) <> (company_id IS NOT NULL)`, per-owner partial-unique
indexes, both FKs `ON DELETE CASCADE`). Every handle write — a member's
`username_changeset` (register / rename), a company's `Companies.claim_handle/2`
— upserts its registry row **in the same transaction** as the owner write
(`Vutuv.Handles.put_user_handle/2` / `put_company_handle/2`), so a colliding
claim loses on the unique index instead of racing. Resolution itself reads the
owner tables directly and never touches `handles`; the registry is purely the
write-time uniqueness lock. `Vutuv.Handles.validate_handle/2` is the single
grammar definition (Twitter style `^[a-z0-9_]+$`, 3-15, lowercased, never a
`ReservedSlugs` word), shared by both owner changesets.

Claiming is owner-only, on the company **edit** page (`CompanyLive.Edit`,
"Root handle" card). It is opt-in and first-come-first-served across the shared
namespace; a company without a handle is unchanged (reachable only at
`/companies/:slug`).

The same edit page has an owner-only **Danger zone** with a permanent
**Delete this company** action (confirm-gated, `owner?`-only, re-checked in the
handler because a non-owner admin can also reach the edit page): it runs the
`delete_company/1` chokepoint (cascades domains / roles / aliases / images /
likes / bookmarks / the `handles` row, settles any moderation case, purges the
on-disk image files) and so frees the company's verified domains **and** its
`@handle` for re-claim. Site admins keep delete plus the reversible
`archive_company/1` (soft "archived" status) in `/admin/companies`; owners have
only the hard delete.

**Resolution + canonical.** The root `/:slug` resolver
(`VutuvWeb.Plug.UserResolveSlug`, `dispatch_company: true` on the bare profile
route only) keeps the member fast path (`users.username`), and on a miss renders
the matching company's page in place via `CompanyController.render_page/2`. So a
handled company serves at **both** `/:handle` and `/companies/:slug` (200), with
the root URL as **canonical**: `render_page/2` sets the `:canonical_url` assign
(honored by `OpenGraph.canonical_url/1`) so `/companies/:slug` carries
`rel="canonical"` → `/:handle`; the sitemap (`Vutuv.Sitemap.company_entries/1`)
and the agent-doc self-links (`CompanyDoc`) list the root URL too. Member-only
sub-pages (`/:slug/followers`, ...) never dispatch to a company (the
`:user_pipe` uses the resolver without the option), so a company handle 404s
there. Rollout was one additive, N-1-safe deploy (new table + backfill of every
member's handle + nullable `companies.username`).

## Trust model

Edit rights over a page come **only** from proving control of the domain, never
from a self-asserted employment claim. Two proof methods, both proving control
of the domain itself. The proof mechanics live in the shared
`Vutuv.WebVerification` (also used by verified personal-webpage links — see
`profiles.md`); `Vutuv.Companies.Verification` is the company-flavoured wrapper
that owns the company gate and test seams:

- **DNS** — a `vutuv-company-verify=<token>` TXT record on the domain.
- **Website file** — the token served at
  `https://<domain>/.well-known/vutuv-company-verify.txt`, fetched with `Req`
  behind the SSRF guard (`Vutuv.Ssrf`), never following redirects.

The company scheme (`vutuv-company-verify=` / `/.well-known/vutuv-company-verify.txt`)
is deliberately distinct from the `vutuv-verify=` scheme personal-webpage links
use (see `profiles.md`), so proving a link never doubles as proving a company on
the same host, and a domain owner can hold both proofs at once via one DNS zone
or two separate well-known files.

There is deliberately **no e-mail method**. An address like `…@gmail.com` proves
control of a *mailbox*, not of the *domain*, so anyone with a Gmail account
could otherwise claim the gmail.com page. DNS and the well-known file both prove
control of the domain.

Both methods are network calls, so they are gated by
`config :vutuv, :verify_company_domains` (env `VERIFY_COMPANY_DOMAINS`, default
on). Off = company domain verification is disabled on the installation (no
outbound calls); existing verified pages keep working, but no new page can be
created.

Domain identity is the **exact host**: `sub.example.com` and `example.com` are
distinct, so a subsidiary or brand with its own (sub)domain can verify its own
page even when the parent's domain is already claimed. No public-suffix list.
The `company_domains.domain` column is `UNIQUE` across the table — the
anti-squatting anchor: one verified domain belongs to exactly one company. One
company may hold several verified domains (multi-TLD setups, a rebrand keeping
the old domain); exactly one is `primary?` (a partial unique index enforces it),
and the public page shows "Verifiziert über *company.tld*" with that primary
domain — the domain, not the name, is what viewers trust.

## Lifecycle

`companies.status`: `pending` → `active` → (`frozen` | `archived`).

- The claim wizard (`/companies/new`, logged-in email-confirmed members) creates
  a `pending` company plus an owner `CompanyRole` and an unverified primary
  `CompanyDomain` derived from the website URL.
- The owner finishes the claim on the page's verification panel (shown to the
  owner while the page is `pending`): publish the record/file, click **Verify
  now**. A successful proof stamps `verified_at`, flips the page to `active`, and
  sends an operator notice (`Emailer.company_verified_notice/2`) so a human
  reviews every new page while volume is low.
- DNS / well-known domains are **re-checked weekly**
  (`Vutuv.Companies.DomainRecheckSweeper`, gated by
  `:recheck_company_domains`; the sweeper ticks hourly but only re-checks
  domains whose last check is older than the weekly interval, spreading the load
  rather than bursting it). A domain whose record/file has vanished enters a
  grace window (`grace_deadline_at`, 7 days); once it passes, the domain loses
  verified status, and if it was the company's last verified domain the page
  falls back to `pending` and the operator is alerted
  (`Emailer.company_unverified_notice/2`).

## Team roles (`company_roles`, #930)

A page is run by a team, not just its claimant. Each `CompanyRole` grants a
proof-derived **power**, never an employment claim:

- **owner** — everything: roles, domains, the page + aliases, and (from issue 5)
  job postings.
- **admin** — the page + aliases and job postings, but not roles or domains.
- **recruiter** — job postings only.

The predicates live in `Vutuv.Companies`: `owner?/2`, `can_edit_page?/2`
(owner ∪ admin), `can_manage_roles?/2` and `can_manage_domains?/2` (owner). The
older `can_manage?/2` is the *staff* predicate (creator ∪ any role holder) used
for **visibility** — a recruiter still sees a pending/frozen page — not for
writes.

Invariant: **every company keeps ≥ 1 owner.** `remove_role/1` and `update_role/3`
refuse to remove or demote the last owner (`{:error, :last_owner}`), exactly like
the last-domain rule. A grant is a notification: the `company_roles` row is a
source of the derived notification feed (`Vutuv.Activity.company_role_items/3`,
self-grants excluded so the claim wizard's owner row is not "news"), and
`Activity.notify_company_role/4` pushes the live badge/toast at grant time. The
owner-only roster lives at `/companies/:slug/roles`
(`VutuvWeb.CompanyLive.Roles`, add by `@handle`/email with a live typeahead
`Companies.suggest_members/2`).

## Multi-domain management (`/companies/:slug/domains`, #930)

A company may prove several domains. Exactly one is `primary?` (the partial
unique index enforces it); it is the one shown in the "Verifiziert über …"
badge. `Companies.add_domain/3` creates a further **non-primary, unverified**
`CompanyDomain`; the owner finishes it with the same #929 wizard on the domains
page, which flips it to verified without touching the (already active) company
status. `set_primary_domain/2` only accepts a verified domain and flips
atomically (old primary off, then new on, so the one-primary index is never
violated mid-write). `remove_domain/2` refuses the **last verified** domain
(`{:error, :last_domain}`) and, when it removes the primary, auto-promotes the
oldest remaining verified domain so the badge follows. The periodic re-check
(`DomainRecheckSweeper`) drops a failing **non-last** domain with an operator
alert (`Emailer.company_domain_dropped_notice/2`); only losing the **last**
verified domain sends the page back to `pending`.

## Aliases (`company_names`, #930)

Alternative names a company is findable under (solves #851): a company that
trades under several names — its registered name vs. a product brand — is found
under all of them, because the directory and admin search match names **and**
aliases (`Companies.name_or_city_ilike/2` adds an `EXISTS` over `company_names`).
`kind` is `alias | former | brand | abbreviation`. A **rename** auto-appends the
old name as a `former` alias (`update_company/2` in an `Ecto.Multi`), so the
rename history is data, not a log file; the slug never changes, so old URLs keep
resolving. Aliases join the page's agent formats (`.md`/`.txt` "Also known as"
line, `.json`/`.xml` `aliases` list — `CompanyDoc.build_show/3`) and the public
page's "Also known as" card, and are edited by owner/admin on
`/companies/:slug/edit`.

**Collision guardrail:** an alias equal (case-insensitive) to another *verified*
company's name or alias is stored but stamped `flagged_at` for the admin queue
(`Companies.add_alias/3`) — there is deliberately **no** user-facing warning or
confirmation. Identical company names are common and legitimate (many unrelated
"Müller GmbH"s), so a warning would imply wrongdoing in the normal case and, in
the abuse case, only tip off a squatter; a human reviews every flag quietly on
`/admin/companies`.

## Machine visibility

Two owner toggles, same semantics as a member's `noindex?`/`noai?`:

- `seo?` (default on) — off ⇒ `noindex`, no `Organization` JSON-LD, out of the
  sitemap.
- `geo?` (default on) — off ⇒ the `.md`/`.txt`/`.json`/`.xml` siblings 404 and
  the page leaves `/llms.txt` and the directory's agent-format listings.

Only an active, non-frozen page serves agent formats, and only for a viewer who
is not the owner does the anonymous doc render (a `.md` URL never serves HTML;
pending/frozen/archived pages 404 their siblings for everyone, cache-safe like a
hidden profile). See `VutuvWeb.AgentDocs.CompanyDoc` and
`agents-and-seo.md`.

## Engagement

Like + bookmark reuse the shared `Vutuv.Engagement` insert kernel. Like counts
are public and live over PubSub (topic `"company:<id>"`, `compact_count`);
bookmarks are private and listed under the member's `/bookmarks` hub (a
Companies sub-tab). Both cascade on company or user deletion.

## Moderation

The report → freeze → case machinery (`Vutuv.Moderation`, see
`moderation.md`) is extended with the content type `company`. A first report
never freezes a verified page; it lands in the admin queue (profile-case
style). A second trusted reporter, or the spam threshold, freezes the page:
frozen pages vanish for the public but stay visible to the owner + admins behind
the owner banner. Reporting a company does **not** sever the reporter's personal
ties to whoever claimed it. The strike ladder lands on the owning member.

## Images

The logo is a `CompanyImage` (the `post_images` pattern) served through the
authorizing proxy `/company_images/:token/:version` (`Vutuv.CompanyImageStore`,
`VutuvWeb.CompanyImageController`), so a pending/frozen page's logo is
owner/admin-only. A page with no logo renders an initials tile. `company_images`
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
