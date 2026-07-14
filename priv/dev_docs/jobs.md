# Jobs API

Post, manage and read job openings and the organizations behind them, so an
HR tool never has to drive the browser. Two scopes:

* `jobs:read` — read the board, one posting, and organization pages (the same
  a signed-in member sees on the website).
* `jobs:write` — create, edit, publish, close and discard **your own** postings.
  Implies `jobs:read`.

Base URL `https://vutuv.de/api/2.0`, bearer token, `application/problem+json`
errors — see [the reference](/developers/reference) and
[authentication](/developers/authentication). In the examples `$API` is
`https://vutuv.de/api/2.0` and `auth()` adds your token:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
export API="https://vutuv.de/api/2.0"
auth() { curl -sS -H "Authorization: Bearer $VUTUV_TOKEN" "$@"; }
```

## The lifecycle

A posting is not a rented slot you keep bumping — it lives at most 90 days,
then it is honestly done:

```text
draft ──publish──▶ published ──90 days pass──▶ expired ──30 days──▶ owner-only
                     │
                     └──closure (filled | withdrawn)──▶ closed
```

* **Publishing** stamps `expires_on` to 90 days out. There is **no renewal
  endpoint** — a role that is still open gets a fresh posting (a new URL, an
  honest `posted_on`), so nothing on the board is ever older than 90 days.
* An **expired or closed** posting cannot be edited or reopened; `PATCH` and
  the publish flow refuse it (`409`, `reason: not_editable`). Repost instead:
  read the old posting, `POST` its fields as a new draft.
* The API posts through the exact same `Vutuv.Jobs` changesets and policies as
  the website — quotas, the account-age gate, organization attribution only
  with a role, the salary and anti-discrimination checks, the rate limiter. An
  API posting is indistinguishable from a form one.

`status` in a response is the **effective** status: a published posting past
its `expires_on` reads as `expired` even before the nightly sweeper flips it.

## Read the board

### GET /jobs

Scope `jobs:read`. The viewer-scoped public board, newest first,
cursor-paginated. Same filters as the website's `/jobs`:

| Query param | Meaning |
|-------------|---------|
| `q` | full-text over title + description |
| `tag` | a tag slug the posting carries |
| `near` + `radius` | a city or postal code, and one of `10`/`25`/`50`/`100` km |
| `country` | an ISO 3166-1 alpha-2 code (`DE`), remote postings match on applicant country |
| `salary_min` | a yearly figure, or `mine` for your own stored expectation |
| `workplace_type` | `onsite` / `hybrid` / `remote` |
| `employment_type` | `full_time`, `part_time`, `contract`, … |
| `my_tags` | `1` to keep only postings matching a tag on your profile |

```bash
auth "$API/jobs?near=Köln&radius=50&salary_min=60000&limit=25"
auth "$API/jobs?cursor=NEXT_CURSOR_FROM_LAST_PAGE"
```

```json
{
  "type": "jobs",
  "jobs": [
    {"id": "0190…", "title": "Backend Engineer (m/w/d)",
     "url": "https://vutuv.de/jobs/backend-engineer-…",
     "employer": {"name": "ACME GmbH", "verified": true, "url": "…"},
     "employment_type": "Full-time", "workplace_type": "On-site",
     "location": {"zip_code": "50667", "city": "Köln", "country": "DE",
                  "country_name": "Germany"},
     "remote_countries": [],
     "salary": {"min": 60000, "max": 80000, "currency": "EUR", "period": "year"},
     "tags": [{"name": "Elixir", "slug": "elixir", "url": "…"}]}
  ],
  "more": true,
  "next_cursor": "SFMyNTY…"
}
```

The board lists only live, published, publicly visible postings you are allowed
to see; blocks and members-only visibility are applied server-side.

### GET /jobs/:id

Scope `jobs:read`. One posting by its `id`, with the full structured location,
salary, tags and its lifecycle `status` + dates. As the **owner** you read a
posting in any state (your tooling needs the final state of an expired or closed
one); everyone else reads only a currently live, published posting (`404`
otherwise).

```bash
auth $API/jobs/0190abcd-…
```

```json
{
  "type": "job_posting",
  "id": "0190…",
  "status": "published",
  "visibility": "everyone",
  "title": "Backend Engineer (m/w/d)",
  "description": "We are hiring …",
  "employer": {"name": "ACME GmbH", "verified": true, "url": "…"},
  "employment_type": "Full-time",
  "workplace_type": "On-site",
  "location": {"zip_code": "50667", "city": "Köln", "country": "DE",
               "country_name": "Germany"},
  "street_address": "Domkloster 4",
  "coordinates": {"lat": 50.9413, "lon": 6.9583},
  "remote_countries": [],
  "salary": {"min": 60000, "max": 80000, "currency": "EUR", "period": "year"},
  "language": "de",
  "posted_on": "2026-07-14",
  "expires_on": "2026-10-12",
  "closed_at": null,
  "close_reason": null,
  "required_tags": [{"name": "Elixir", "slug": "elixir", "url": "…"}],
  "nice_to_have_tags": [],
  "apply": {"kind": "url", "target": "https://acme.example/careers/42"}
}
```

## Write your postings

### POST /jobs

Scope `jobs:write`. Create a draft, or publish in one call with
`"publish": true`. Fields (all optional on a draft except `title`):

`title`, `hiring_org_name` (free-text employer for a personal posting),
`description` (Markdown), `employment_type`, `workplace_type`,
`street_address`, `zip_code`, `city`, `country`, `remote_countries` (a list of
ISO codes, for a remote posting), `salary_min`, `salary_max`,
`salary_currency` (default `EUR`), `salary_period` (default `year`),
`apply_kind` (`url`/`email`/`message`), `apply_url`, `apply_email`,
`language`, `visibility` (`everyone`/`members`), `seo?`, `geo?`,
`required_tags` and `nice_to_have_tags` (a comma-separated string or a list),
`image_ids`, and `organization` (a verified organization's slug — allowed only
if you hold a role there).

```bash
# A draft (only a title is required)
auth -X POST $API/jobs -H "Content-Type: application/json" \
  -d '{"title": "Backend Engineer (m/w/d)"}'

# Create and publish in one call
auth -X POST $API/jobs -H "Content-Type: application/json" -d '{
  "title": "Backend Engineer (m/w/d)",
  "workplace_type": "onsite", "zip_code": "50667", "city": "Köln", "country": "DE",
  "employment_type": "full_time",
  "salary_min": 60000, "salary_max": 80000, "salary_currency": "EUR", "salary_period": "year",
  "apply_kind": "url", "apply_url": "https://acme.example/careers/42",
  "required_tags": "Elixir, Phoenix",
  "publish": true
}'
```

Answers `201` with the posting document. **Publishing enforces completeness**:
an onsite/hybrid draft needs `zip_code` + `city` + `country`, a remote draft
needs `remote_countries`, and every non-volunteer posting needs a full salary
range — otherwise a `422` with per-field errors. A `POST` with `publish: true`
is atomic: it either returns a published posting or a clean error and creates
nothing.

### PATCH /jobs/:id

Scope `jobs:write`, own postings only. Edit any field. On a **draft**, pass
`"publish": true` to go live (the same completeness checks apply; a failed
publish keeps your draft so you can fix and retry). A key you omit is left
unchanged — including `organization`, whose current attribution is kept unless
you send the key.

```bash
# Fill in the missing fields and publish the draft
auth -X PATCH $API/jobs/0190… -H "Content-Type: application/json" -d '{
  "zip_code": "50667", "city": "Köln", "country": "DE",
  "salary_min": 60000, "salary_max": 80000,
  "apply_kind": "url", "apply_url": "https://acme.example/careers/42",
  "publish": true
}'
```

Editing an expired or closed posting answers `409` (`reason: not_editable`).

### POST /jobs/:id/closure

Scope `jobs:write`. End a live posting early with a reason:

```bash
auth -X POST $API/jobs/0190…/closure -H "Content-Type: application/json" \
  -d '{"reason": "filled"}'
```

`reason` is `filled` or `withdrawn`. Answers `200` with the posting (`status:
"closed"`). Only a live posting can be closed (`409` otherwise).

### DELETE /jobs/:id

Scope `jobs:write`. Discard a **draft** (`204`). A published posting cannot be
discarded — close it instead (`409`, `reason: not_draft`) — so the lifecycle
stays honest.

## Organizations

### GET /organizations

Scope `jobs:read`. Verified organization pages, alphabetical, `?page=N` and a
`?q=` search over name / city / alias.

```bash
auth "$API/organizations?q=acme&page=1"
```

### GET /organizations/:slug

Scope `jobs:read`. One organization page with its aliases, verified domains,
postal address, linked people and open positions — the employer behind a
posting. The path segment may be the organization's slug **or** its claimed root
handle (whatever the last segment of its `url` in the listing is).

```bash
auth $API/organizations/acme-gmbh
```

```json
{
  "type": "organization",
  "name": "ACME GmbH", "slug": "acme-gmbh", "kind": "Company",
  "website_url": "https://acme.example",
  "verified_domains": ["acme.example"], "primary_domain": "acme.example",
  "aliases": [{"name": "ACME Cologne", "kind": "trade_name"}],
  "city": "Köln", "country": "DE", "country_name": "Germany",
  "address_line": "Domkloster 4, 50667 Köln, Germany",
  "people_total": 12, "people": [{"name": "…", "title": "…", "url": "…"}],
  "open_positions": [{"id": "0190…", "title": "…", "url": "…", "salary": {"…": "…"}}]
}
```

## The `job.published` webhook

Instead of polling the board, subscribe to `job.published` (needs the poster's
`jobs:read` grant) and hear about a member's new openings as they go live.
Unlike every other topic this payload carries the posting's **public structured
fields** — the same the board shows — so you can mirror an opening without a
follow-up fetch. It never carries anything that is not already on the public
posting. See [Webhooks](/developers/webhooks) for the delivery and signature
contract.

```json
{
  "event": "job.published",
  "occurred_at": "2026-07-14T09:00:00Z",
  "member": "wintermeyer",
  "data": {
    "id": "0190…",
    "url": "https://vutuv.de/jobs/backend-engineer-…",
    "title": "Backend Engineer (m/w/d)",
    "employer": "ACME GmbH",
    "employment_type": "full_time", "workplace_type": "onsite",
    "zip_code": "50667", "city": "Köln", "country": "DE", "remote_countries": [],
    "salary": {"min": 60000, "max": 80000, "currency": "EUR", "period": "year"},
    "tags": ["Elixir", "Phoenix"]
  }
}
```

## Errors you will meet

| Status | `reason` | When |
|--------|----------|------|
| `403` | `attribution_denied` | you named an `organization` you have no role at |
| `403` | `account_too_new` / `email_unconfirmed` | your account cannot publish yet |
| `404` | — | the posting does not exist or is not visible to you |
| `409` | `member_quota` / `organization_quota` | too many postings live at once |
| `409` | `not_editable` | editing an expired or closed posting |
| `409` | `not_closeable` | closing something that is not live |
| `409` | `not_draft` | deleting a published posting (close it instead) |
| `422` | — | incomplete location, missing salary range, unknown organization, or a bad `reason` |

Applications and people search over the API are out of scope; an "easy apply"
routes the candidate to the employer's own channel, and vutuv stores no
applications table.
