# Verified organization pages

Organization pages live at `/organizations/:slug`, with a public directory at
`/organizations`. The defining rule (issue #929): **an organization page can only exist
once someone proves control of the organization's web domain.** There are no
unverified pages, which kills the "first user creates a typo'd organization name"
foot-gun at the root.

Context: `Vutuv.Organizations`. Schemas under `lib/vutuv/organizations/`.

## Entry points & discoverability

Two member-facing surfaces, split by audience:

- **Public directory** (`/organizations`, `VutuvWeb.OrganizationLive.Index`): the
  crawlable browse-and-search list of every `active` + non-frozen page, with the
  agent-format siblings and a sitemap entry. Linked from the footer. Its header
  says in one line what an organization page is (a verified page for a company,
  association, school, public authority or other group, not a person); the
  "Add your organization" button opens the claim wizard.
- **The member's "Your organizations" hub** (`/settings/organizations`,
  `SettingsController.organizations` + `templates/settings/organizations.html.heex`):
  a login-required settings page listing the pages the member owns or helps run
  (`Organizations.member_organizations/1` → `{organization, role}` pairs,
  **including pending** pages still finishing verification and frozen ones,
  archived dropped), each with its status chip, the member's role, and (for an
  owner/admin) a "Manage" link into `/organizations/:slug/edit`. It carries the
  plain-language explainer of *what* an organization is and *how ownership works*
  (whoever creates a page becomes its owner, can invite admins/recruiters, can
  hand ownership over, can claim an @handle), written for a member who has never
  heard the term. The **account menu** "Organizations" item and the settings
  sidebar both point here; the public directory stays one click away via the
  footer and the page's "Browse all organizations" link.

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
`@handle` for re-claim. A page **with job postings is archive-only for the
owner** (`Organizations.deletable?/1`, the issue #932 rule — deleting would
detach its postings' attribution); site admins keep the unconditional delete
plus the reversible `archive_organization/1` (soft "archived" status) in
`/admin/organizations`.

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

- **DNS** — a `vutuv-organization-verify=<token>` TXT record on the domain, or on
  the CNAME-safe `_vutuv.<domain>` alternate name for a domain that is itself a
  CNAME (see `profiles.md` and `WebVerification.dns_challenge_name/1`, issue #947).
  The record is read from the zone's **own name servers** (`Vutuv.Dns`), not
  through a recursive resolver — see "Why the DNS read bypasses the cache" below.
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
  owner while the page is `pending`, at the page's own permanent URL
  `/organizations/:slug`, and reachable from `/settings/organizations`, where a
  pending row shows a **Finish verification** call to action instead of the
  generic "Manage"): publish the record/file, click **Verify now**. A successful
  proof stamps `verified_at`, flips the page to `active`, and sends an operator
  notice (`Emailer.organization_verified_notice/2`) so a human reviews every new
  page while volume is low.
- **The claim also finishes on its own** (`Vutuv.Organizations.PendingDomainSweeper`,
  issue #1466). Publishing a DNS record does not complete when the member
  presses Save at their provider; it completes minutes or hours later, out of
  their hands. So a pending domain is re-checked on a backoff ladder read from
  its own age — `@pending_backoff`, every two minutes for the first quarter of
  an hour, flattening to six-hourly and abandoned after 30 days — and on success
  the owners get `Emailer.organization_domain_verified_email/4` and any open page
  is told over the organization's PubSub topic, so it turns into the live page with
  no reload. Both sweepers share the `:recheck_organization_domains` gate.
  `check_domain/2` stamps `last_checked_at` on **every** outcome, including the
  failures, or a domain that can never verify would hold the front of every
  oldest-first batch for ever.
- DNS / well-known domains are **re-checked weekly**
  (`Vutuv.Organizations.DomainRecheckSweeper`, gated by
  `:recheck_organization_domains`; the sweeper ticks hourly but only re-checks
  domains whose last check is older than the weekly interval, spreading the load
  rather than bursting it). A domain whose record/file has vanished enters a
  grace window (`grace_deadline_at`, 7 days); once it passes, the domain loses
  verified status, and if it was the organization's last verified domain the page
  falls back to `pending` and the operator is alerted
  (`Emailer.organization_unverified_notice/2`).

### Why the DNS read bypasses the cache

`Vutuv.Dns` finds the deepest ancestor of the queried name that has `NS`
records, resolves those name servers and asks **them** for the TXT record,
rather than asking the recursive resolver in `/etc/resolv.conf`. That is not an
optimisation, it is the difference between the feature working and not:

- A claim is almost always started **before** the record exists — the member has
  to read the value off the panel to publish it. That first look primes the
  resolver's **negative** cache for the zone's SOA negative TTL, commonly hours,
  and a short TTL on the record published seconds later cannot shorten it. Every
  later "Verify now" then gets the same cached "no" from a resolver that is
  working exactly as designed (issue #1466).
- Every authoritative server is asked, not only the first, because a zone whose
  servers are mid-transfer answers differently depending on who you ask.
- An answer without the `aa` bit is discarded (`Vutuv.Dns.InetRes.txt_at/2`), so
  a referral is never read as "no record", and a bare TLD is never used as the
  zone (`zone_candidates/1`), since its registry servers only ever refer.
- Name-server addresses come out of DNS, which the claimed domain's owner
  controls, so an address `Vutuv.Ssrf.internal_ip?/1` calls internal is dropped:
  an `NS` record pointing at `127.0.0.1` or a metadata endpoint must not turn
  this server into a probe.
- When no zone can be found or nothing answers — split-horizon intranet
  resolvers, a firewall allowing port 53 only to the configured resolver — the
  plain recursive lookup still runs, so this can only make verification more
  likely to succeed.

The panel reports what the check actually read (`WebVerification.dns_check/4` /
`well_known_check/4` → `VerificationComponents.check_report/1`): the names
queried, the value wanted, and every TXT record found there. A member whose SPF
record is listed back at them can see in one line that the proof went to the
wrong name, which "not found yet, please try again" never told them. That block
is an assign and not a flash on purpose — an identical flash renders no diff, so
the old toast made every attempt after the first look like a dead button.

`Organizations.check_domain/2` is the **only** way to run a domain's proof. It
used to have a twin (`verify_domain/2` and its per-method variants) that
answered a bare `{:error, :not_found}` and stamped nothing; two entry points for
one question is how the next caller silently gets no report and no
`last_checked_at`, which the background pass reads to back off. The report
component is shared with the personal-webpage link proofs (`profiles.md`) — same
question, same answer, one rendering — and each caller passes its own
`disabled_text`, since "domain verification" and "link verification" are
separate installation switches.

### Who hears about a failing proof

Two audiences, two mails, and they must not be confused. The
`Emailer.organization_*_notice/2` builders go to the installation's
**operator** (`:operator_recipient`) and link to `/admin/organizations`, the
oversight dashboard — a page the organization's own staff cannot even open. On
their own they leave the one person who can republish the proof uninformed,
which is why the **owners** get their own mails (`Organizations.owners/1`, each
in their own locale, linking to `/organizations/:slug/domains`):

- **Grace start** — `Emailer.organization_domain_grace_email/5`, sent **once per
  window** from the `:grace_started` arm. The `:in_grace` re-checks stay silent;
  a weekly nag is how a warning mail gets filtered away. The subject and the
  body branch on `last?` (`verified_domain_count/1 <= 1`), so a page with other
  verified domains is not told it is about to go offline.
- **Demotion** — `Emailer.organization_page_unverified_email/4`, sent alongside
  the operator notice when the last verified domain is dropped.
- **Verified in the background** — `Emailer.organization_domain_verified_email/4`,
  sent only from the pending pass, never from a click: somebody watching the
  page being verified does not need a mail about it, and the whole point of this
  one is that it reaches the member who published the record and closed the tab.

Recipients are **owners only**: domains are an owner-only power
(`can_manage_domains?/2`), so an admin or recruiter would get a call to action
they cannot follow. The domains page is the landing spot for both mails, so a
domain in its grace window renders an amber "Proof missing" pill plus the
deadline there, and its verification panel (record/file + **Verify now**) is
shown for a grace-window domain as well as a never-verified one — otherwise the
mail's recipient would arrive at a green "Verified" badge contradicting it.

## Team roles (`organization_roles`, #930)

A page is run by a team, not just its claimant. Each `OrganizationRole` grants a
proof-derived **power**, never an employment claim:

- **owner** — everything: roles, domains, the page + aliases, and job postings.
- **admin** — the page + aliases and job postings, but not roles or domains.
- **publisher** — speaking in the organization's name: publishing, editing and
  deleting its posts, and switching into it (#1333, #1334, #1335). Nothing
  administrative.
- **recruiter** — job postings only.

**A member holds any number of roles on any number of pages** (#1333). The
unique index is `[organization_id, user_id, role]`, effective powers are the
union, and `roles_of/2` answers with a ranked list. It was renamed from
`role_of/2` rather than quietly re-typed: a permission accessor whose return
moves from `"owner" | nil` to a list under the same name is how a check ends up
reading a non-empty list as truthy.

**`publisher` is never implied**, not by `owner` and not by `admin`. Speaking
for a page and administering it are different powers that usually belong to
different people, so a freshly claimed page cannot post until its owner grants
it once. The separation holds structurally rather than by convention, because
`can_manage_roles?/2` is owner-only: an admin cannot grant themselves the right
to post. German label "Redaktion" — it names the function, not a rank.

The predicates live in `Vutuv.Organizations`: `owner?/2`, `can_edit_page?/2`
(owner ∪ admin), `publisher?/2`, `can_manage_roles?/2` and
`can_manage_domains?/2` (owner). The older `can_manage?/2` is the *staff*
predicate (creator ∪ any role holder) used for **visibility** — a recruiter
still sees a pending/frozen page — not for writes.

**Every channel maps onto these four roles and adds none of its own.** The
Mastodon-compatible client adapter (`Vutuv.MastodonApi.Access`) is the case
that tested the rule: it lets a member hold a page as a separate identity in a
phone app, and it resolves that identity through `publisher?/2` — the same
predicate `acting_organization/2` asks for the browser's identity switch. A
client is a second way to reach the powers the Redaktion already has, never a
new power and never a new grant. The one thing an organization identity can
never hold is the `write:blocks` scope: a block is between two people, it cuts
both ways, and a page is not one of the two.

### The staff feed (designed, not built)

The case the four roles do not cover: a whole workforce should be able to
**read** what its company's social-media team has curated, without any of them
being able to speak in the company's name. Today the only way to open
`/organizations/:slug/feed` is `publisher`, which also grants posting and
`/act_as` — far too much for "let me read our reading list".

The design below is deliberately small, because one thing that could have made
it big turns out to be already true: **the organization feed's action bar
already acts as the reading member, not as the page** (see
`OrganizationLive.Feed`). So a reader needs no companion role for interacting,
and no second identity is involved anywhere in this feature. That is also why
it must stay that way: an earlier draft of the Mastodon work quietly switched
that bar to act as the page, which is a different feature wearing the same
buttons. Speaking *as* the page keeps its own deliberate, visible route,
`/act_as` (#1335), which none of this touches.

**One role, `social_reader`: may read the page's feed, nothing else.** It is
the cheap half of the split (`publisher` satisfies it, so no existing gate
moves and nothing has to be backfilled). A `social_manager` — follows and
mutes without publishing — is *not* part of this: it moves
`/organizations/:slug/following` off `publisher` and therefore needs a role
row backfilled for every current publisher, which is a separate decision with
a migration attached.

**Granted from a verified domain, per domain, default off.** An organization
already proves domains by DNS or well-known. It should be able to say, for one
verified domain at a time, "anybody holding an email address on this host may
read our feed". Four things this rests on, each checked:

- **An `emails` row is already proof of control.** There is no `verified_at`
  column because there is no unverified state: an address is PIN-confirmed
  *before* the row is inserted (`VutuvWeb.EmailController` create → confirm),
  and `Email.update_changeset/2` cannot change `value` afterwards. Nothing new
  has to be built to establish trust in the address.
- **Match the exact host, like `OrganizationDomain` does** — not
  `Vutuv.EmailDomain`'s suffix rule, which the exclusion lists use
  (`example.com` also matching `eu.example.com`). Two domain semantics already
  live in this codebase and picking the wrong one here would admit
  `name@mail.acme.com` on a host Acme never proved, widening silently with
  every new subdomain. Acme adds and verifies each mail domain instead, which
  the per-domain switch makes visible anyway.
- **Say what the grant actually means.** The domain proof establishes DNS
  control, deliberately with no email method (see `OrganizationDomain`) — so
  what it licenses is "can receive mail at a host we control", which is not the
  same as "is an employee". Alumni, ex-colleagues whose mailbox still exists,
  contractors and shared aliases all pass it. The admin UI should say that
  rather than "employees".
- **Default off, because the feed reveals the follow list.** A reader can infer
  what the page follows, and that list is deliberately not public (see
  `OrganizationLive.Following`: what a company watches says more about its
  plans than a member's reading list says about theirs). The switch is
  therefore "show our interests to everybody with an address on this host", and
  it should read like one.

**Derive the grant, never materialise it.** Domain-derived access must not
insert `organization_roles` rows. Materialising it brings back both problems
this document already records — a backfill on deploy and rows that outlive
their reason — and would fill the owner's roster with hundreds of automatic
entries. As a derived predicate it also revokes correctly and immediately:
when the switch goes off, when the domain loses verification (it has a
`grace_deadline_at` and a recheck sweeper), or when the member deletes the
address.

**It belongs on `/feed`, with a URL.** Sending employees to
`/organizations/:slug/feed` is the wrong door — that page is the team's
workspace. `/feed` grows one tab per organization the viewer may read, beside
All / vutuv / Fediverse (`VutuvWeb.PostComponents.post_filter_tabs/1` already
takes an `options` list, which is the seam). Today none of those tabs has a
URL: `filter-source` is a plain `phx-click` with no `push_patch`, and only
`/feed` itself is routed. Giving them URLs needs one decision made up front:

- **Sources as a query parameter, organizations as a path segment** —
  `/feed?source=vutuv` beside `/feed/<org-slug>`. If both were path segments,
  `/feed/fediverse` would be ambiguous with an organization slugged
  `fediverse`. Splitting them by kind removes the collision without reserving
  any words. Should `/feed/<something>` ever need a non-organization meaning
  (`/feed/saved`), that word has to be reserved then.
- **Key on `slug`**, not `organizations.username`: the root handle is optional.
- `feed` is already a root path word, so a sub-path burns no member handle and
  needs no `ReservedSlugs` entry.
- `/feed` already has agent-format siblings that are **private**, not the usual
  anonymous public view (`VutuvWeb.AgentDocs.FeedDoc`: 404 without a viewer,
  `private, no-store`). A per-organization feed follows that same pattern.

The query layer needs nothing new: `Posts.organization_feed_page/2` already
scopes its sources anonymously (`scope_visible(nil)`) and takes `viewer:` for
decoration only — which is exactly "the page's reading list, my own
interaction state".

Two smaller things noticed while mapping the above, neither urgent:
`PostLive.ActionBar.acting_page/1` resolves its organization with a bare
`Repo.get/2`, so if the page row is gone it falls back to `page || user` and
the act lands on the **member's** account; resolving through
`acting_organization/2` instead would answer nil and do nothing. And a token
minted for a page has no expiry (see `Vutuv.ApiAuth.OAuth`), which is why the
per-request role re-check is doing more work here than anywhere else.

Invariant: **every organization keeps ≥ 1 owner.** `remove_role/1` and
`set_roles/4` refuse to remove or demote the last owner (`{:error, :last_owner}`),
exactly like the last-domain rule. `set_roles/4` is the roster's one write — it
diffs against what is held, so an unchanged role keeps its `granted_by` and its
age — and it replaced the single-role `update_role/3` when the roster became a
checkbox set. That shape is deliberate: with a select, granting `publisher` to
an admin would silently have taken their `admin` away. A grant is a notification: the `organization_roles` row is a
source of the derived notification feed (`Vutuv.Activity.organization_role_items/3`,
self-grants excluded so the claim wizard's owner row is not "news"), and
`Activity.notify_organization_role/4` pushes the live badge/toast at grant time. The
owner-only roster lives at `/organizations/:slug/roles`
(`VutuvWeb.OrganizationLive.Roles`, add by `@handle`/email with a live typeahead
`Organizations.suggest_members/2`). It is **one row per member with a checkbox
set** (`list_team/1`), not one row per role; nothing is pre-ticked on the add
form, because with four roles a guessed default is wrong more often than right
and `publisher` must never arrive by accident.

## Speaking as a page (#1334, #1335, #1336)

A page is an identity, not only a brochure. What it can do now, and where each
piece lives:

- **It publishes.** `posts` carries `user_id | organization_id` (CHECK exactly
  one) plus `acting_user_id` — who pressed publish, `nilify_all`, never shown.
  **`Vutuv.Posts.author/1` is the one accessor**; reading `post.user` on an
  organization post is the bug to look for. Editing and deleting follow the
  **role, not the person**: any current publisher may, because the post belongs
  to the page. Organization posts carry no audience and cannot be replied to
  (both refused outright rather than half-working).
- **A member switches into it** for a session (#1335). The session carries only
  `acting_as_organization_id`, and it is a **hint, never a credential**:
  `VutuvWeb.Plug.ActingAs` and `Live.InitAssigns.acting_as/2` re-ask
  `organization_roles` on every request and every socket mount, so a withdrawn
  role ends the mode on the next action. Both directions are in the account
  activity log under their own kinds.
- **Members follow it.** `follows.followee_organization_id` (nullable pair +
  CHECK, #1336) — only the followee side; a page following somebody is not built.
  Its posts then reach the follower's feed through `feed_organization_post_items/3`.
- **It sees what happens to it** at `/organizations/:slug/activity`: new
  followers, likes and reposts of its posts, and posts naming it by handle.
  Derived from the source tables, so an unliked post is not "read" — it never
  happened. **One read marker for the whole team** (`activity_read_at`): read
  means somebody read it, never that everybody did, which is why it is a column
  on the page and not a row per member. The marker is the newest entry's
  timestamp rather than the wall clock (second-precision tables + a strict `>`),
  and an empty list stamps nothing.
- **It can be written to** (#1336). `conversations` carries a nullable
  `organization_id` beside `user_b_id` (CHECK: exactly one other side), so a
  member↔page conversation is `user_a_id` = the member, `user_b_id` NULL. The
  sorted pair did **not** have to be generalised: sorting exists to break the
  symmetry between two ids from the *same* table, and a member and a page come
  from different ones, so `(user_a_id, organization_id)` is already canonical.
  There is no request/accept dance (a page publishes in order to be addressed),
  the page's side of `conversation_participants` is **one row for the whole
  team** like `activity_read_at`, and a reply is sent in the page's name with
  `messages.acting_user_id` recorded and never shown. Reading and answering
  happen at the ordinary `/messages`, whose inbox is whichever identity the
  session is currently speaking as — see `messages.md`.
- **It is mentionable** by its root handle, and reachable from search, the tag
  pages, the sitemap, `/llms.txt`, its own RSS feed and the agent formats.

### It federates (issue #1334)

A page can be an ActivityPub actor: findable from Mastodon, followable, and its
posts reach the accounts that follow it. The whole of it hangs off one
owner-only switch that ships **off** (`organizations.fediverse_followers?`), and
a page must have claimed a handle first, because the handle is its address out
there. The details live in `fediverse.md` under "A page federates too" — this
note is here so nobody has to guess which document to open.

### The trap this shape carries

Every one of those surfaces reaches the author. Widening `posts.user_id` to
nullable produced **eleven silent failures**, in three flavours: `NOT IN` over a
nullable column (never true — it emptied the discovery rail), an inner join
through `users` (dropped the rows entirely — search, reposts, the saved list,
tag pages, the site feed), and reading `post.user` or hand-building
`~p"/#{post.user}/posts/…"` (raised — notifications, the admin gallery, the
daily report mail). None was reported by a user; all were found by sweeping.

So when the next kind of actor arrives: enumerate every module that **reads**
the thing, not the one that stores it, and route the URL through the function
that owns it.

`conversations` then charged the same toll a second time, in the same three
flavours: `Repo.one!(where: u.id == ^nil)` **raised** (the member's whole
`/messages` was a 500 once they had written to a page), and three separate
`sender_id != <id>` tests answered NULL rather than true for a page's message,
so its reply counted as unread nowhere and the notification mail for it was
never sent. A fourth hid in the *fix* and was caught only because the test
asserted both directions. The lesson holds: for a column that is now nullable,
`x != v` and `x == v` both need an explicit `is_nil` arm, and the test has to
watch the un-fixed code fail.

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
`/admin/organizations` (the drawer's per-alias **Clear** action resolves a
reviewed-and-fine flag via `Organizations.clear_alias_flag/1`).

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

Like + bookmark run on the shared `Vutuv.Engagement` fabric (the config-driven
engage/disengage + counts layer job postings use too; the org config keeps the
`:organization_counters` / `:organization_engagement_changed` message names its
LiveViews pattern-match). Like counts
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
