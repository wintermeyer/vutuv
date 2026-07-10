# Verified company pages

Company pages live at `/companies/:slug`, with a public directory at
`/companies`. The defining rule (issue #929): **a company page can only exist
once someone proves control of the company's web domain.** There are no
unverified pages, which kills the "first user creates a typo'd company name"
foot-gun at the root.

Context: `Vutuv.Companies`. Schemas under `lib/vutuv/companies/`.

## Trust model

Edit rights over a page come **only** from proving control of the domain, never
from a self-asserted employment claim. Two proof methods, both proving control
of the domain itself (`Vutuv.Companies.Verification`):

- **DNS** — a `vutuv-verify=<token>` TXT record on the domain.
- **Website file** — the token served at
  `https://<domain>/.well-known/vutuv-verify.txt`, fetched with `Req` behind the
  SSRF guard (`Vutuv.Ssrf`), never following redirects.

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
- DNS / well-known domains are **re-checked periodically**
  (`Vutuv.Companies.DomainRecheckSweeper`, gated by
  `:recheck_company_domains`). A domain whose record/file has vanished enters a
  grace window (`grace_deadline_at`, 7 days); once it passes, the domain loses
  verified status, and if it was the company's last verified domain the page
  falls back to `pending` and the operator is alerted
  (`Emailer.company_unverified_notice/2`).

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
which stores display names. The full postal address is required at claim time
and feeds the `Organization` JSON-LD as a `PostalAddress`.
