# vutuv API

vutuv offers a RESTful JSON API at `https://vutuv.de/api/2.0` so your scripts
and apps can read and (soon) write vutuv data on behalf of a member who
authorized them.

* [Authentication & tokens](/developers/authentication) — how to get and use
  an access token, scopes, rate limits, errors.
* [Cookbook](/developers/cookbook) — copy-paste answers to "how do I post
  something?", "how do I send or read a direct message?" and friends.
* [The data model](/developers/data-model) — what members, posts, tags,
  follows, connections and conversations are and how they relate.
* [API reference](/developers/reference) — every endpoint, with examples.

This documentation is also available as plain Markdown: append `.md` to any
page URL (for example [`/developers.md`](/developers.md)) — handy for AI
tools and offline reading.

## Quickstart: your first request in two minutes

1. Log in to vutuv and open [Access tokens](/access_tokens).
2. Create a token. Pick a name and the `profile:read` permission. Copy the
   token — it is shown exactly once.
3. Call the API:

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" \
     https://vutuv.de/api/2.0/me
```

You get your own profile as JSON, seen through your own eyes (including
entries only you can see):

```json
{
  "type": "profile",
  "schema_version": 1,
  "name": "Stefan Wintermeyer",
  "slug": "stefan.wintermeyer",
  "emails": ["stefan@example.com"],
  "counts": {"followers": 1208, "following": 341, "connections": 86, "posts": 412},
  "tags": [{"name": "Phoenix", "endorsements": 31}],
  "...": "..."
}
```

Read another member's profile (you see what you would see on the website,
never more):

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" \
     https://vutuv.de/api/2.0/users/stefan.wintermeyer
```

## The API in five sentences

1. **Versioned.** Everything lives under `/api/2.0`. Additions (new fields,
   new endpoints) happen without notice and never break you; breaking
   changes only ever appear under a new prefix (`/api/3.0`).
2. **Token-authenticated.** Every request carries
   `Authorization: Bearer <token>`. Members create tokens themselves and can
   revoke each one (or all of them) with one click — revocation is
   effective on the very next request.
3. **Scoped.** A token can only do what the member allowed it to do
   (for example `profile:read` or `posts:write`).
4. **Through the member's eyes.** Reads return what the authorizing member
   would see on the website — the same visibility rules, enforced
   server-side.
5. **JSON in, JSON out.** Success responses are `application/json`; errors
   are [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem documents
   (`application/problem+json`) with a human-readable `detail`.

## No token? Public data is still open

Every public vutuv page also serves machine-readable formats under the same
URL plus an extension — without any token, exactly as an anonymous visitor
sees it:

```bash
curl https://vutuv.de/stefan.wintermeyer.json   # profile as JSON
curl https://vutuv.de/stefan.wintermeyer.md     # profile as Markdown
curl https://vutuv.de/stefan.wintermeyer.vcf    # profile as vCard
```

See [`/llms.txt`](/llms.txt) for the full list of public pages. Use the
authenticated API when you need the member's own view, write access, or
stable rate limits.

## What the API covers today

Reading and writing across the whole product, as the authorizing member:
profile and its sections, follows and connections, posts (composing,
audiences, images, replies, likes/bookmarks/reposts, your feed), direct
messages (the request model included) and the notification feed. See the
[reference](/developers/reference).

For real third-party apps there is **OAuth 2** (authorization code +
PKCE): register your app at [/developers/apps](/developers/apps), send
members through a consent screen instead of pasting tokens — see
[Authentication & tokens](/developers/authentication#oauth-2-for-third-party-apps).
Registered apps can also receive **[webhooks](/developers/webhooks)** —
signed event deliveries instead of polling.

## Development, bugs and feature requests

vutuv is **open source** (MIT), built with Elixir and the Phoenix
Framework. Development happens in the open at
[github.com/wintermeyer/vutuv](https://github.com/wintermeyer/vutuv):

* **Found a bug?** Open an issue at
  [github.com/wintermeyer/vutuv/issues](https://github.com/wintermeyer/vutuv/issues)
  — what you did, what you expected, what happened instead. For API bugs,
  include the request (with the token redacted!) and the response.
* **Missing a feature?** Open an issue too, and describe the use case
  rather than the solution — what are you trying to build?
* **Security issues** go privately to
  [sw@wintermeyer-consulting.de](mailto:sw@wintermeyer-consulting.de)
  (see [/.well-known/security.txt](/.well-known/security.txt)), never into
  a public issue.
* **Pull requests are welcome.** The README in the repository explains how
  to run vutuv locally; every change ships with tests.

## Roadmap

The core API is feature-complete. What comes next is driven by what
developers build — tell us what you are missing.

Questions or a use case the API does not cover yet? Write to
[sw@wintermeyer-consulting.de](mailto:sw@wintermeyer-consulting.de).
