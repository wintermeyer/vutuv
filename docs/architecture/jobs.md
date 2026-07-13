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
  a **bidirectional block** today (`Vutuv.Social.blocked_user_ids/1`); the #939
  per-posting poster-exclusion list plugs into the same `board_exclude/2` step
  when it lands. Newest first (`first_published_at`, UUID v7 `id` tiebreaker),
  keyset-paginated (`%{entries:, more?:, cursor:}`; the web layer signs the
  `{first_published_at, id}` cursor with `VutuvWeb.ApiV2`).
- **Filters** (all URL params): `q` (Postgres full-text over title +
  description, `websearch_to_tsquery`), `tag` (slug), `workplace`, `employment`,
  `salary_min` (+ currency — same-currency only, the posting's yearly-normalised
  `salary_max` must reach the floor), `near` + `radius` + `country` (location),
  and the signed-in-member chips `my_tags` ("Passend zu meinen Tags") and
  `salary_min=mine` ("ab meiner Gehaltsvorstellung", resolved server-side from
  the member's #928 expectation — the stored figure is never rendered).
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

## Agent formats & JSON-LD

The detail page carries `JobPosting` JSON-LD (only when `indexable?`), with
`validThrough = expires_on`, the mapped `employmentType`, `jobLocation`
(Place/PostalAddress) for on-site/hybrid or `jobLocationType: TELECOMMUTE` +
`applicantLocationRequirements` for remote, `baseSalary`, `skills` from the tags
(required first) and `hiringOrganization`. The `.md/.txt/.json/.xml` siblings
come from `VutuvWeb.AgentDocs.JobPostingDoc` (drift-tested against the HTML).
