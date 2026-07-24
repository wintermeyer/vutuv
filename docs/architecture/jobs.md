# Job postings

`Vutuv.Jobs` — job postings, their 90-day lifecycle, engagement, tags,
structured location and the salary model (issue #932). A member who never posts
a job never sees any of this; there is one new namespace, `/jobs/…`.

## Data model

`job_postings` (all ids UUID v7):

- **`user_id`** (required) — the responsible human. **`organization_id`**
  (nullable) attributes the posting to a verified organization page, settable
  only by a role holder there (`Vutuv.Organizations.can_manage?/2`); otherwise
  the free-text **`hiring_org_name`** is shown, always as an unverified employer.
- **`title`**, **`description`** (Markdown, max 10 000 chars, the same Milkdown
  editor / renderer / CommonMark profile as posts).
- **`employment_type`** (`full_time … volunteer`), **`workplace_type`**
  (`onsite | hybrid | remote`), **`apply_kind`** (`url | email | message`),
  **`status`** (`draft | published | expired | closed`), **`visibility`**
  (`everyone | members`), **`close_reason`** — `Ecto.Enum`s with `*_label/1`
  single sources on `Vutuv.Jobs.JobPosting`.
- **Location.** For on-site and hybrid: `street_address` (optional),
  `zip_code`, `city`, `country` (ISO 3166-1 alpha-2 via `Vutuv.Countries`). For
  remote: `remote_countries` (non-empty ISO array — where applicants must be
  located). `lat`/`lon` are resolved offline at save time from `zip_code` +
  `country` (see below) and are `nil` when unresolvable — the posting still
  publishes; coordinates are an optimisation, never a gate.
- **Salary** — whole-unit integers (`salary_min`/`salary_max`), `salary_currency`
  (`EUR | USD | GBP | CHF`), `salary_period` (`hour … year`), the shared
  `Vutuv.Salary` model. Never `:decimal` (the codebase models money as integers).
- **`seo?`**/**`geo?`** — the poster's machine-visibility toggles.
- Lifecycle stamps: `first_published_at`, `expires_on` (Berlin date), `closed_at`,
  plus `view_count`/`apply_click_count` and the moderation `frozen_at`.

Satellite tables: `job_posting_tags` (with a `priority: required | nice_to_have`),
`job_posting_images` (the post-image pattern 1:1 — token/version storage, served
through the authorizing `/job_posting_images/:token/:version` proxy, purged with
the posting), and `job_posting_likes` / `job_posting_bookmarks` (the shared
Engagement building block, both cascading on posting or user deletion).

## Lifecycle

```
draft ──publish──▶ published ──expires_on passes──▶ expired ──30 days──▶ owner-only
                     │
                     └──close (filled | withdrawn)──▶ closed
```

Publishing sets `expires_on = today (Berlin) + runtime_days` (90 by default) and
stamps `first_published_at` once. **There is no renewal or bumping**: a
still-open role gets a fresh posting via `repost/2` (a one-tap clone with honest
new dates and a new URL), which keeps the hard guarantee that nothing on the
board is older than 90 days.

`Vutuv.Jobs.Sweeper` runs once per Berlin day (00:10 local, DST-aware, the
`DailyReporter` scheduling pattern; off in tests via `:jobs_sweeper`): it e-mails
each poster whose posting expires in 7 days (through the `Emailer` chokepoint,
transactional — no opt-out) and flips overdue published postings to `expired`.
Demotion to owner-only (a posting expired more than 30 days ago) needs no DB
write — `Vutuv.Jobs.visible_to?/2` computes it from the dates
(`effective_status/1` + the 30-day grace window).

## Visibility

Three orthogonal gates, mirroring the organization pages, all read through
`Vutuv.Jobs.visible_to?/2` (the detail page, the agent docs and — later — the
board):

| Gate | Off means |
|---|---|
| `visibility: members` | signed-in members only; out of the public board, JSON-LD, sitemap and every agent format, regardless of `seo?`/`geo?` |
| `seo?: false` | no `JobPosting` JSON-LD, `noindex`, out of the sitemap |
| `geo?: false` | the `.md/.txt/.json/.xml` siblings 404 and it leaves `/llms.txt` |

`indexable?/1` (sitemap + JSON-LD) and `agent_visible?/1` (agent formats) both
require a *live* posting (`published`, not frozen, `visibility = everyone`, not
past expiry). `indexable_query/0` is the one crawlable-set definition, delegated
to by `Vutuv.Sitemap`.

Beyond the three gates, `visible_to?/2` subtracts the **exclusion list** (see
[Exclusion lists](#exclusion-lists-issue-939) below) as its **last** step, so an
excluded signed-in viewer gets the same not-found result as any non-visible
posting; an anonymous viewer is never excluded.

## Exclusion lists (issue #939)

The poster-side twin of the member exclusion list (`Vutuv.Accounts.ViewerExclusion`,
issue #938): "keep this posting on the board for everyone **except** a chosen few"
(competitors, your own staff, a specific person). `Vutuv.Jobs.Exclusions` owns
the whole seam; the `job_exclusions` table holds it.

- **Subject** (exactly one, DB check): a single **posting**'s own list
  (`job_posting_id`), or a verified **organization**'s standing default
  (`organization_id`) that every posting attributed to it inherits. A posting's
  **effective** set is `own rows ∪ owning-org default rows` (union; the per-posting
  editor can add but not un-inherit an org default).
- **Target dimension** (exactly one, DB check): a **member** (`excluded_user_id`),
  an **organization** (`excluded_organization_id` — its verified domains, its role
  holders, and members whose **current** work experience links to it), or an email
  **domain** (`domain` — that host and any subdomain of it, host-suffix match, no
  public-suffix list). Domain shape/normalization is shared with #938 via
  `Vutuv.EmailDomain`.
- **The predicate.** `Exclusions.exclude_for_viewer(query, viewer)` is the one
  composed subtraction (the effective-list match minus the poster / owning-org-staff
  exemptions, plus the bidirectional block), and `Exclusions.excluded?(posting,
  viewer)` is answered by the same `matching_posting_ids/1`, so no surface can
  disagree by construction (issue #954 closed the drift). Both resolve the viewer's
  scope once (`resolve_scope/1`: account id, confirmed-email hosts, and every org
  they belong to via role ∪ current work experience ∪ verified-domain email).
- **Never excluded:** the **poster**, the **owning organization's staff** (a role
  holder), and an **anonymous** viewer (exclusion only narrows the signed-in
  on-platform audience — pair `visibility: members` with the list to also hide from
  logged-out viewers). A **block** (either direction) always excludes.
- **Silent by design** (mirrors `Social.block_user`): an excluded viewer gets the
  same not-found/hidden result as any non-permitted viewer, with no signal.
- **Enforcement surfaces**, all through the two functions above: the detail page +
  its agent-format siblings (`visible_to?/2`), the board + its filters/search
  (`board_scope/1`), saved-search alerts (`new_board_postings/3` shares
  `board_scope/1`), the `/api/2.0` jobs endpoints (share `board_page`/`visible_to?`),
  the bookmarks/likes hub (`saved_job_postings_page/3`), and the organization / tag
  pages' "Offene Stellen" sections (`list_organization_postings/3`,
  `list_tag_postings/3` — viewer-scoped in HTML, `nil` = the anonymous view the
  agent formats render).
- **Editors.** Per-posting: `VutuvWeb.JobPostingLive.Exclusions` at
  `/jobs/:slug/exclusions` (owner-only). Organization default:
  `VutuvWeb.OrganizationLive.Exclusions` at `/organizations/:slug/exclusions`
  (any role holder, `manage_header` "Job exclusions" tab). Both render the shared
  `VutuvWeb.JobExclusionComponents.exclusion_panel/1`.
- **Cleanup** is pure FK cascade: every column (`job_posting_id`, `organization_id`,
  `excluded_user_id`, `excluded_organization_id`) is `on_delete: :delete_all`, so a
  row disappears with its subject **or** its target — no chokepoint code. Cap: 200
  entries per subject (`Exclusions.cap/0`).

## The public board (`/jobs`, issue #933)

`VutuvWeb.JobBoardLive` is the board, embedded via `live_render` from
`VutuvWeb.JobPostingController.index` (off-router, like the profile / feed /
organization pages) so the controller negotiates the agent-format siblings
(`/jobs.md/.txt/.json/.xml`). Being off-router it has no `handle_params` /
`push_patch`, so **filter state lives entirely in the URL**: the search form is a
plain GET, every chip and the "More jobs" link is a real `<a href>` (shareable,
and the crawl path — the board is a shared-footer + top-bar nav link). PubSub
(topic `"jobs"`) keeps an open page live.

- **Base scope.** `Jobs.board_page(viewer, filters, opts)` starts from
  `board_scope/1`, which folds the visibility gate (`everyone` for anyone,
  `members` additionally for a signed-in viewer) and the exclusion seam into one
  query, so no downstream filter can leak a hidden posting. The exclusion seam is
  the one composed `Exclusions.exclude_for_viewer/2` (bidirectional block + the
  #939 exclusion list minus the poster/staff exemptions, see
  [Exclusion lists](#exclusion-lists-issue-939)). Newest first (`first_published_at`, UUID v7 `id` tiebreaker),
  keyset-paginated (`%{entries:, more?:, cursor:}`; the web layer signs the
  `{first_published_at, id}` cursor with `VutuvWeb.ApiV2`).
- **Filters** (all URL params): `q` (Postgres full-text over title +
  description; see the search grammar below), `tag`, `workplace`, `employment`,
  `salary_min` (+ currency — same-currency only, the posting's yearly-normalised
  `salary_max` must reach the floor), `near` + `radius` + `country` (location),
  and the signed-in-member chip `my_tags` ("Passend zu meinen Tags").
- **Tag filter, multi-select (issue #951).** `tag` is a **comma-separated list
  of slugs** (`?tag=elixir,phoenix`); a single slug is the degenerate case, so
  old `?tag=elixir` links and the tag-page/card links still work. Semantics are
  **OR** (`filter_tags/2`: a posting matches when it carries *any* selected
  tag), so adding a tag broadens — the standard board facet, consistent with the
  `my_tags` chip. The board renders each active tag as a removable pill and
  offers the current results' other tags as one-tap `+` suggestions; a free-text
  `add_tag` field (native `<datalist>` typeahead) resolves a typed name to its
  canonical slug (`Tag.find_by_value/1`) and folds it into `tag` in `mount` (an
  unknown name is dropped — only existing tags can filter). The transient
  `add_tag` never reaches a link.
- **Salary filter, two ways in (issue #953).** A `salary_min` number field
  ("Mindestgehalt/Jahr", `#job-salary-min`) is open to **every** viewer —
  logged out, or a member with no #928 expectation — and files a bare yearly
  figure compared in `Jobs.default_currency/0` (the installation's first
  `Vutuv.Salary` currency, EUR on vutuv.de). A signed-in member who has stored
  a minimum-salary expectation additionally gets the one-tap
  `salary_min=mine` chip ("ab meiner Gehaltsvorstellung", resolved server-side
  from the #928 figure — the stored figure is never rendered). The two share
  the one `salary_min` slot, so they are mutually exclusive: while `mine` is
  active the number field is disabled and a hidden `mine` token rides along,
  so the private figure is never seeded into the field or submitted.
- **Search grammar (`q`, issue #952).** A role has no single canonical title, so
  the box lets one search cover several. `Vutuv.Jobs.SearchQuery.to_tsquery/1`
  turns the human box into a **`to_tsquery('simple', …)`** string (not
  `websearch_to_tsquery` any more, which only speaks the English `or` keyword):
  **comma / newline / `|` / a standalone `or`|`oder`** → OR between titles
  (locale-neutral, so a German visitor's `oder` works); **space** → AND;
  **trailing `*`** → prefix wildcard (`entwickl*` → Entwickler/Entwicklung,
  valuable because `simple` does no stemming); **`"quoted words"`** → adjacent
  phrase; **leading `-`** → global exclusion. Every token is reduced to
  lexeme-safe characters and the expression assembled from well-formed pieces
  only, so visitor input can never make `to_tsquery` raise (unit-tested in
  `search_query_test.exs`); a query with no searchable token is a no-op. The
  board renders a "Suchtipps" disclosure with worked examples. Because
  `board_page/3` and the alert sweeper share `apply_board_filters/3`, a saved
  OR/wildcard search alerts on the same grammar.
- **Location.** `near` (a city or zip) resolves to a point offline via
  `Vutuv.Geo.resolve_point/2` (zip first, then city); onsite/hybrid postings
  match within `radius` km by a great-circle (haversine) predicate in SQL, or by
  a case-insensitive city / exact-zip text fallback when coordinates are unknown
  (so nothing silently disappears). A **remote** posting stays in whenever its
  applicant countries include the searched country ("near me *or* remote for
  me"); the workplace chips narrow from there.
- **Cards** (`VutuvWeb.JobComponents.job_card/1`, shared with the organization
  and tag sections): title, the employer trust block, chips, salary (or
  "Ehrenamtlich"), the posting's tags with a signed-in viewer's own tags
  highlighted, and the age ("vor 3 Tagen"). On the board each card carries the
  in-process like / bookmark bar (`phx-click`, no per-card nested LiveView); the
  organization and tag sections render the card statically (their pages own other
  `toggle_like`/`toggle_bookmark` handlers, or are dead pages).
- **Live updates.** Publishing, closing, freezing and the nightly sweeper's
  bulk-expire each `Jobs.notify_board_changed/0` on the `"jobs"` topic; an open
  board re-queries its current page so a matching posting appears or a hidden one
  disappears without a reload.
- **Agent formats.** `Jobs.agent_board_page/1` + `VutuvWeb.AgentDocs.JobBoardDoc`
  are the anonymous public view — only `everyone`, `geo?` postings, each entry
  carrying the structured location / salary / tag fields
  (`JobPostingDoc.summary/1`) so agents filter client-side, cursor-paginated with
  a `next` link. **No `JobPosting` JSON-LD on the list** (leaf pages only).
- **Scoped sections.** `Jobs.list_organization_postings/2` and
  `Jobs.list_tag_postings/2` power the "Offene Stellen" sections on
  `/organizations/:slug` and `/tags/:slug` (the tag section links into the
  pre-filtered board, `/jobs?tag=…`); both sections join their pages' agent-doc
  builders and the drift test.

## Trust UI & compliance

- **Employer block** — a verified organization shows its name linked to the page
  with a verified mark; a personal posting shows the poster's profile card, with
  any `hiring_org_name` as plain, clearly-unverified text.
- **AGG hint** — `JobPosting.agg_hint?/1` is a *non-blocking* nudge that fires
  when the title contains **none** of a short, documented allowlist of neutral
  markers (`(m/w/d)` and its orderings, `(m/w/x)`, `(gn)`, "all genders", and the
  `*innen`/`:innen`/`_innen`/`/-innen`/`/innen` forms). It deliberately does not
  parse gendering variants and cannot detect a gendered base title, so incomplete
  markers like `(m/w)` still get the hint — the case that matters legally. The
  wording says it is a suggestion, not legal advice; AGG responsibility stays
  with the poster.
- **Pay range required to publish** (drafts may be incomplete; only `volunteer`
  postings are exempt and render "Ehrenamtlich"). We lead ahead of the EU
  pay-transparency directive 2023/970 rather than waiting for its German
  transposition. There is no field anywhere asking applicants for their
  current/previous salary (the directive bans that question).
- **No applications table** — applying routes to the employer's channel (an
  outbound URL, a prefilled mailto, or a vutuv conversation with the poster), so
  vutuv never becomes controller of rejected-candidate data (§26 BDSG / AGG).

## Salary normalization

Cross-period comparison (for the board and alerts) normalises each figure to a
**yearly equivalent** with fixed, documented factors, and **never converts
currencies** (a different currency simply does not match — no FX guessing). The
factors (`Vutuv.Salary.yearly_equivalent/2`):

| period | × factor | rationale |
|---|---|---|
| hour | 1720 | a German full-time year (~40 h/week over ~43 worked weeks) |
| day | 220 | worked days per year |
| week | 52 | |
| month | 12 | |
| year | 1 | |

They are deliberately coarse — they bucket figures for matching, not to compute
anyone's real pay.

## Offline location (`Vutuv.Geo`)

Postal-code → coordinate resolution is entirely offline, backed by a bundled
[GeoNames](https://www.geonames.org/) postal dataset (CC BY 4.0), one standard
tab-separated file per country under `priv/geo/<CC>.txt` or `<CC>.txt.gz`. vutuv
ships `DE`, `AT` and `CH`. No outbound call, no network flag — safe on an
air-gapped intranet. `Vutuv.Geo.Postal` parses the configured `:geo_countries`
once, on first use, into a `:persistent_term` index. `:default_country`
preselects country inputs.

To add a country: download its GeoNames zip export
(`download.geonames.org/export/zip/<CC>.zip`), drop the extracted `<CC>.txt` (or
gzip it to `<CC>.txt.gz`) into `priv/geo/`, and add the code to `GEO_COUNTRIES` —
see [ADMINS.md](../ADMINS.md).

## Moderation

Job postings plug into the existing report → freeze → case machinery as the
content type `job_posting`, with a specific report category "Irreführende
Stellenanzeige" (`misleading_job`). A report from a member in good standing
freezes the posting for the public instantly (owner + admins keep it) and alarms
the admin queue. A freeze (`frozen_at`) is the compliance-critical gate: it pulls
the posting off the public board, the sitemap, JSON-LD and every agent format at
once (all keyed on `frozen_at` through `visible_to?`/`indexable?`/`agent_visible?`),
and the public detail 404s for anyone but the owner/admin, so there is no noindex
page left carrying JSON-LD — `jobs_freeze_compliance_test.exs` guards this.

### Admin oversight (`/admin/jobs`, issue #934)

`VutuvWeb.Admin.JobLive` is the oversight dashboard (see `admin.md` for the full
UI): tiles (live / expiring / frozen / open cases), a title/poster/organization
search, status + "open reports" filter chips, and a per-posting detail drawer
(poster, employer attribution, counters, report history, poster footprint) with
reload-free **freeze/unfreeze** (`Jobs.admin_set_frozen/2` — the same `frozen_at`
gate, pinging the board), **close** (`Jobs.admin_close/1`, `:moderation` reason)
and **delete** (`Jobs.delete_job_posting/1`). The context helpers
(`admin_overview_counts/0`, `admin_jobs_page/1`, `admin_job_detail/1`,
`member_job_footprint/1`) live in the `# admin dashboard (#934)` section of
`Vutuv.Jobs`. Repeat offenders lose the account through the standard strike ladder
(`moderation.md`), which the report path already feeds.

The same `member_job_footprint/1` also drives the **member detail page**
(`/admin/users/:id`, `VutuvWeb.Admin.UserDetailLive`, see `admin.md`), which the
member browser links to: an admin looking into one member sees their live/total
postings, open job cases and cold-outreach spend there too, not only in the
per-posting drawer.

### Anti-spam recruiting: the cold-outreach cap

`Vutuv.Chat` caps **cold outreach** — new message *requests* one member opens to
strangers (members who don't already follow them). Only a new *pending*
conversation counts; replying to an accepted thread never does. The cap
(count + window) is a per-installation knob (`config :vutuv, :cold_outreach`,
`COLD_OUTREACH_LIMIT` / `COLD_OUTREACH_WINDOW_HOURS`, default 20 / 24h), enforced
through `Vutuv.RateLimiter`; over the cap the member gets a friendly "try again
later". `Chat.cold_outreach_count/1` reads the current spend without moving it
(`RateLimiter.peek/2`), so the `/admin/jobs` poster footprint can show it when a
recruiter's messaging is questioned.

## Saved searches and alerts

A signed-in member can save the current board filters from the quiet "Save
search" control (shown whenever a filter is active) and pick an alert cadence
(`none` / `daily` / `weekly`, defaulting to `none` so saving never silently
subscribes). This is symmetric with the people side: both are rows in one
`saved_searches` table owned by `Vutuv.SavedSearches`, capped per member
(`config :vutuv, :saved_searches, max_per_member`, `SAVED_SEARCHES_MAX_PER_MEMBER`,
default 10). The stored `query` is the exact `/jobs` (or `/search`) URL query
string, so `Vutuv.Jobs.board_filters/2` — the one raw-params → filters parser
the live board and the sweeper share — replays the identical search. A
`salary_min=mine` filter is stored verbatim, so it resolves against the member's
live salary expectation (#928) at sweep time and the private figure is never
written into the query column or any mail.

`Vutuv.SavedSearches.AlertSweeper` runs once per Berlin day (a few minutes after
the lifecycle sweeper, so an expiring posting is already off the board). It
batches **one** digest per member: each notifying search due today is re-run for
matches created after its `last_notified_at` high-water mark (the DM-notification
pattern), up to five per search, and the searches with new matches are listed
with a link to the full results. Jobs use `Jobs.new_board_postings/3` (the same
visibility + block + #939 exclusion gate as the live board, so an excluded member
is never alerted to a posting they cannot see); people use
`Search.new_matching_people/3`. The high-water mark advances to the sweep cutoff
afterwards, so a match is mailed at most once. The digest is bulk mail
(`Emailer.saved_search_alert_email/3` + `bulk_headers/1`) with a member-level
one-click `List-Unsubscribe` (`saved_search_emails?`) and a per-search disable
link (`VutuvWeb.SavedSearchToken`, `/unsubscribe/search/:token`). Members manage
their searches at `/settings/saved_searches` (the row joins the settings hub only
once the first search is saved).

## Agent formats & JSON-LD

The detail page carries `JobPosting` JSON-LD (only when `indexable?`), with
`validThrough = expires_on`, the mapped `employmentType`, `jobLocation`
(Place/PostalAddress) for on-site/hybrid or `jobLocationType: TELECOMMUTE` +
`applicantLocationRequirements` for remote, `baseSalary`, `skills` from the tags
(required first) and `hiringOrganization`. The `.md/.txt/.json/.xml` siblings
come from `VutuvWeb.AgentDocs.JobPostingDoc` (drift-tested against the HTML).

## `/api/2.0` (issue #936)

The whole lifecycle is a second door on the same room: `VutuvWeb.ApiV2.JobController`
(`jobs:read`/`jobs:write`) reuses the exact `Vutuv.Jobs` context — `board_page/3`
+ `board_filters/2` for `GET /jobs`, `create_draft/3`/`publish/4`/`update_posting/4`/
`close/2`/`delete_job_posting/1` for the writes — so an API posting is
indistinguishable from a form one (same quotas, gate, validations, 90-day
lifecycle). Responses reuse `JobPostingDoc` (`api_show/1` = the public show doc
plus the owner-only `id`/`status`/`street_address`/`coordinates`/close fields,
never drifting from the shared shape). `VutuvWeb.ApiV2.OrganizationController`
serves the organization directory + page read-only from `OrganizationDoc`. A
successful **first** publish (draft → published, never an edit) emits the
`job.published` webhook from `Vutuv.Jobs.publish/4` — the one topic whose payload
carries the posting's public structured fields (see the API subsystem doc). Full
developer reference: `priv/dev_docs/jobs.md` (`/developers/jobs`).
