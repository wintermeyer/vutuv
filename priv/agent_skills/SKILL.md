---
name: vutuv
description: Read and work with vutuv, the free social/business network. Use this skill to fetch member profiles, posts, tags and listings as Markdown/JSON/vCard instead of scraping HTML, to subscribe to post feeds, and to call the authenticated /api/2.0 REST API for writing (posts, follows, messages).
---

# vutuv for agents

vutuv is a free social/business network. Every public page has
machine-readable siblings — prefer them over parsing HTML.

## Page formats

Append an extension to any public URL (or send the matching `Accept`
header):

- `<page>.md` — Markdown with YAML frontmatter (`Accept: text/markdown`)
- `<page>.txt` — plain text, 80 columns (`Accept: text/plain`)
- `<page>.json` — flat JSON document (`Accept: application/json`)
- `/<username>.vcf` — the profile as vCard 3.0 (`Accept: text/vcard`)

Labels default to English; add `?lang=de` for German. Documents carry
`schema_version` and `generated_at`; responses carry `Content-Signal`,
`X-Markdown-Tokens` (size estimate for Markdown) and a `Link` header
pointing back at the canonical HTML page. Respect `Content-Signal` and
`X-Robots-Tag: noindex` — members can opt out of search/AI use.

## Key URLs

- `/<username>` — member profile
- `/<username>/posts` — post archive (also `/<year>[/<month>[/<day>]]`)
- `/<username>/posts/<id>` — a single post with replies
- `/<username>/followers`, `/following`, `/connections` — people lists
- `/<username>/<section>` — profile sections: `work_experiences`, `links`,
  `social_media_accounts`, `addresses`, `phone_numbers`, `emails`, `tags`
- `/tags/<tag>` — a tag and its most endorsed members
- `/listings/most_followed_users` — the most followed members
- `/search?q=<query>` — member search (HTML)

List pages paginate with `?page=N`.

## Feeds and discovery

- `/<username>/posts/feed.xml` — RSS 2.0, full post content
- `/posts/feed.xml` — the latest public posts site-wide
- `/sitemap.xml` — sitemap index (members, posts, tags)
- `/llms.txt` — the discovery file this skill summarizes

## Writing: the REST API

Authenticated writing (posts, follows, messages, profile
edits) goes through `/api/2.0` — Bearer tokens, scoped permissions,
5,000 requests/hour, RFC 7807 problem+json errors. Read the docs as
Markdown:

- `/developers.md` — overview and quick start
- `/developers/authentication.md` — tokens and OAuth 2
- `/developers/reference.md` — every endpoint
- `/developers/webhooks.md` — signed webhooks
