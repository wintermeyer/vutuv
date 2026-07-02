# vutuv API

Welcome, and thanks for stopping by. vutuv is built by developers who would
genuinely love for you to build on it too. There is a clean RESTful API for
apps and scripts, RSS feeds for readers, public data for anyone, and a codebase
you are warmly invited to improve.

## Start here

Two ways in, both take about a minute. Pick whichever fits you.

### Just want to poke around? No token, no signup.

Every public profile, post and tag is readable right now. Open a terminal and
run:

```bash
curl https://vutuv.de/wintermeyer.json
```

You get that profile as JSON, exactly as an anonymous visitor sees it. Swap in
any username; swap `.json` for `.md`, `.txt` or `.vcf` to get other formats.
[`/llms.txt`](/llms.txt) lists every public page. No account needed, ever.

### Building something? Get your token in under a minute.

To read your own data (including entries only you can see), to write, or to get
stable rate limits, you authenticate with a personal access token. Here is the
whole process:

1. [Log in to vutuv](/login). No account yet? [Create a free one](/) first.
   vutuv is passwordless: you enter your email and type in the PIN we mail you.
2. Open [Access tokens](/access_tokens) and click **Create an access token**.
3. The form arrives with a name already filled in and the **`profile:read`**
   permission ticked, which is all you need to read your own profile. Press
   **Submit**.
4. Copy the token straight away. It starts with `vutuv_pat_` and is shown
   **once**, never again.
5. Send it as a Bearer token:

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" \
     https://vutuv.de/api/2.0/me
```

That returns your own profile as JSON, through your own eyes (including entries
only you can see):

```json
{
  "type": "profile",
  "schema_version": 1,
  "name": "Stefan Wintermeyer",
  "username": "wintermeyer",
  "emails": [{"id": "0190…", "type": "Work", "value": "stefan@example.com"}],
  "counts": {"followers": 1208, "following": 341, "connections": 86, "posts": 412},
  "tags": [{"name": "Phoenix", "endorsements": 31}],
  "...": "..."
}
```

Need to write, not just read? Tick more permission boxes when you create the
token (each one is explained right there on the form, for example
`posts:write` to publish posts). The full list, expiry options and rate limits
are in [Authentication & tokens](/developers/authentication).

## A few easy things to try

Drop your token and a tiny helper into your shell, and every example stays a
one-liner:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
export API="https://vutuv.de/api/2.0"
auth() { curl -sS -H "Authorization: Bearer $VUTUV_TOKEN" "$@"; }

# Read another member's profile (you see what you would on the website):
auth $API/users/wintermeyer

# Read your own feed:
auth $API/feed

# Post something (needs the posts:write permission; the body is Markdown):
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello from the API! **Markdown** works."}'
```

The [Cookbook](/developers/cookbook) has a copy-paste recipe for every common
task: posting images, sending and reading direct messages, following and
connecting, replies, likes, reading notifications and more.

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

## RSS feeds for readers

Prefer to read rather than build? vutuv publishes standard RSS 2.0 feeds with
the full post content, so you can follow along in any feed reader, with no
account and no token:

* Everyone's public posts, site-wide: `https://vutuv.de/posts/feed.xml`
* One member's public posts: `https://vutuv.de/<username>/posts/feed.xml`,
  for example `https://vutuv.de/wintermeyer/posts/feed.xml`

Paste either URL into the feed reader of your choice. We are big fans of RSS
and happy every time someone subscribes.

## What the API covers

Reading and writing across the whole product, as the authorizing member:
profile and its sections, follows and connections, posts (composing,
audiences, images, replies, likes/bookmarks/reposts, your feed), direct
messages (the request model included) and the notification feed. See the
[reference](/developers/reference) for every endpoint.

For real third-party apps there is **OAuth 2** (authorization code + PKCE):
register your app at [/developers/apps](/developers/apps), send members through
a consent screen instead of pasting tokens — see
[Authentication & tokens](/developers/authentication#oauth-2-for-third-party-apps).
Registered apps can also receive **[webhooks](/developers/webhooks)**: signed
event deliveries instead of polling.

## Built by developers, for developers

vutuv is a project by developers who want other developers to join in. It is
**open source** (MIT licence), written in Elixir and the Phoenix Framework,
and developed entirely in the open at
[github.com/wintermeyer/vutuv](https://github.com/wintermeyer/vutuv). Please do
take part:

* **Found a bug?** Open an issue at
  [github.com/wintermeyer/vutuv/issues](https://github.com/wintermeyer/vutuv/issues).
  Tell us what you did, what you expected, and what happened instead. For API
  bugs, include the request (with the token redacted!) and the response.
* **Missing a feature?** Open a feature request, and describe the use case
  rather than the solution: what are you trying to build? The roadmap is driven
  by what developers tell us they need, so this genuinely shapes vutuv.
* **Pull requests are very welcome, and we appreciate every one.** The
  [README in the repository](https://github.com/wintermeyer/vutuv) explains how
  to run vutuv locally; every change ships with tests.
* **Security issues** go privately to
  [sw@wintermeyer-consulting.de](mailto:sw@wintermeyer-consulting.de)
  (see [/.well-known/security.txt](/.well-known/security.txt)), never into a
  public issue.

Questions, ideas, or a use case the API does not cover yet? Write to
[sw@wintermeyer-consulting.de](mailto:sw@wintermeyer-consulting.de). We would
love to hear what you are building.
