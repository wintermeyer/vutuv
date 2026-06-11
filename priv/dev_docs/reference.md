# API reference

Base URL: `https://vutuv.de/api/v1` · All endpoints need a
[bearer token](/developers/authentication) · Errors are
`application/problem+json` ([details](/developers/authentication#errors)).

Responses carry `schema_version` (currently `1`). New fields appear without
notice — parse leniently and ignore keys you do not know. Fields never
disappear or change meaning within `/api/v1`.

## GET /me

Scope: `profile:read`. Your own profile, through your own eyes: private
email addresses and posts only visible to you are included.

```bash
curl -H "Authorization: Bearer $VUTUV_TOKEN" \
     https://vutuv.de/api/v1/me
```

```json
{
  "type": "profile",
  "schema_version": 1,
  "generated_at": "2026-06-11T14:00:00Z",
  "url": "https://vutuv.de/stefan.wintermeyer",
  "title": "Stefan Wintermeyer",
  "name": "Stefan Wintermeyer",
  "first_name": "Stefan",
  "last_name": "Wintermeyer",
  "slug": "stefan.wintermeyer",
  "verified": true,
  "headline_markdown": "Phoenix, Elixir & web performance.",
  "current_position": {"title": "Consultant", "organization": "Wintermeyer Consulting"},
  "member_since": "2016-08-01",
  "avatar_url": "https://vutuv.de/avatars/...",
  "counts": {"followers": 1208, "following": 341, "connections": 86, "posts": 412},
  "emails": ["stefan@example.com", "private@example.com"],
  "phone_numbers": [{"value": "+49 261 9886 9072", "type": "work"}],
  "addresses": [{"description": "Office", "city": "Neuwied", "country": "Germany"}],
  "social_media": [{"provider": "GitHub", "url": "https://github.com/wintermeyer"}],
  "tags": [{"name": "Phoenix", "slug": "phoenix", "endorsements": 31}],
  "work_experiences": [{"title": "Consultant", "organization": "Wintermeyer Consulting", "start": "2010-01"}],
  "links": [{"url": "https://www.wintermeyer-consulting.de", "description": "Company"}],
  "posts": [{"url": "https://vutuv.de/stefan.wintermeyer/posts/0190...", "published_on": "2026-06-10", "excerpt": "..."}]
}
```

(Abridged — fields with no data are empty lists or `null`. The exact entry
shapes match the public `.json` pages, so one parser serves both.)

## GET /users/:slug

Scope: `profile:read`. A member's profile **through your eyes**: you get
what you would see on their profile page logged in as yourself — public
data, plus e.g. private email addresses only if they follow you back. Never
more.

```bash
curl -H "Authorization: Bearer $VUTUV_TOKEN" \
     https://vutuv.de/api/v1/users/stefan.wintermeyer
```

Same response shape as `/me`. Unknown slugs, never-activated accounts and
accounts hidden by moderation answer `404`.

## Public data, without a token

Anonymous public reads do not need the API at all: every public page is
also served as `.json` (and `.md`, `.txt`, the profile as `.vcf`) under its
own URL — the anonymous view, cache-friendly, no auth:

```bash
curl https://vutuv.de/stefan.wintermeyer.json            # profile
curl https://vutuv.de/stefan.wintermeyer/posts.json      # post archive
curl https://vutuv.de/stefan.wintermeyer/followers.json  # follower list
curl https://vutuv.de/tags/phoenix.json                  # a tag page
```

The full page list lives in [`/llms.txt`](/llms.txt). Rule of thumb: use
extension URLs for anonymous public data, `/api/v1` for the member's own
view (and, soon, writes).

## CORS

`/api/v1` sends `Access-Control-Allow-Origin: *` — browser apps can call it
directly. Never embed a long-lived token in shipped client code; tokens
belong server-side or in the user's own hands.

## Versioning promise

* Additive changes (new endpoints, new fields) happen within `/api/v1`.
* Breaking changes (removed/renamed fields, changed semantics) only happen
  in a new version prefix, with a documented migration window.
* The deprecated read-only `/api/1.0` JSON-API endpoints predate this API;
  new integrations must not use them.

## Coming next

Write endpoints (profile sections, posts, follows/connections, messages),
OAuth 2 app registration, and webhooks — see the
[roadmap](/developers#roadmap). This reference only ever documents what is
actually live.
