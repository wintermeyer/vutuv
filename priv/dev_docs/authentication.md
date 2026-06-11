# Authentication & tokens

Every `/api/v1` request must carry a bearer token:

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" \
     https://vutuv.de/api/v1/me
```

There is no anonymous access to `/api/v1`. (Anonymous *public* data is served
by the extension URLs instead — see the
[reference](/developers/reference#public-data-without-a-token).)

## Personal access tokens

A personal access token (PAT) acts as the member who created it, limited to
the permissions ("scopes") they picked.

* Create one at [vutuv.de/access_tokens](/access_tokens) (you need a vutuv
  account, logged in).
* The token starts with `vutuv_pat_` and is shown **exactly once**. vutuv
  stores only a hash; a lost token cannot be recovered, only replaced.
* Tokens optionally expire (30/90/365 days). Pick an expiry unless you have
  a good reason not to.
* Revocation is one click on the same page — per token, or all at once. A
  revoked token fails on its very next request.

Treat tokens like passwords:

* Never commit them. Pass them via environment variables:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
curl -H "Authorization: Bearer $VUTUV_TOKEN" https://vutuv.de/api/v1/me
```

* The `vutuv_pat_` prefix exists so secret scanners can recognize leaked
  tokens. If a token may have leaked, revoke it immediately — replacing it
  costs you one minute.

## Scopes

A token only ever does what its scopes allow. A `*:write` scope implies its
`*:read` sibling.

| Scope            | Allows |
|------------------|--------|
| `profile:read`   | Read your profile, including entries only you can see |
| `profile:write`  | Edit your profile and its sections |
| `social:read`    | See your followers, who you follow, and your connections |
| `social:write`   | Follow people, manage connections, endorse tags |
| `posts:read`     | Read posts visible to you |
| `posts:write`    | Write, edit and delete your posts |
| `messages:read`  | Read your messages |
| `messages:write` | Send messages as you |

Request only the scopes you will use — members see the list when they
create the token, and a narrow token is an easy yes.

## Errors

Errors are [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem
documents with the content type `application/problem+json`:

```json
{
  "title": "Missing scope",
  "status": 403,
  "detail": "This endpoint needs the \"profile:read\" scope, which this token was not granted.",
  "required_scope": "profile:read"
}
```

| Status | Meaning |
|--------|---------|
| `401`  | No token, unknown token, revoked, expired, or the account/app behind it is unavailable. The `detail` says which. |
| `403`  | Valid token, missing scope. `required_scope` names what to add. |
| `404`  | The resource does not exist **or is not visible to you** — deliberately indistinguishable. |
| `429`  | Rate limit exceeded. Honor `Retry-After`. |

## Rate limits

Each token gets 5,000 requests per hour. Every response reports the budget:

```text
x-ratelimit-limit: 5000
x-ratelimit-remaining: 4998
```

Over the limit you receive `429` with a `Retry-After` header (seconds).
Back off and retry after that time; do not hammer.

## Calling the API from code

Anything that speaks HTTPS works. Two minimal examples:

**JavaScript (browser or Node — CORS is open, tokens never go in cookies):**

```javascript
const res = await fetch("https://vutuv.de/api/v1/me", {
  headers: { Authorization: `Bearer ${process.env.VUTUV_TOKEN}` },
});
if (!res.ok) throw new Error(`API error ${res.status}`);
const profile = await res.json();
console.log(profile.name, profile.counts);
```

**Python:**

```python
import os, requests

res = requests.get(
    "https://vutuv.de/api/v1/me",
    headers={"Authorization": f"Bearer {os.environ['VUTUV_TOKEN']}"},
    timeout=10,
)
res.raise_for_status()
profile = res.json()
print(profile["name"], profile["counts"])
```

## Accountability

The API is tied to accounts on both sides: tokens belong to vutuv members,
and (once OAuth app registration ships) third-party applications must be
registered by a vutuv account too. Abuse — spam, scraping beyond the rate
limits, acting against members' interests — leads to token revocation,
app suspension, or account moderation. A suspended app's tokens all stop
working at once.

## OAuth 2 for third-party apps (coming)

Personal access tokens are for your own scripts and trusted tools — the
member has to create and paste the token. For real third-party apps, OAuth 2
(authorization code + PKCE, consent screen, per-app revocation) is on the
roadmap; this page will document it when it ships. The error and scope
mechanics above stay identical.
