# Authentication & tokens

Every `/api/2.0` request must carry a bearer token:

```bash
curl -H "Authorization: Bearer vutuv_pat_YOUR_TOKEN" \
     https://vutuv.de/api/2.0/me
```

There is no anonymous access to `/api/2.0`. (Anonymous *public* data is served
by the extension URLs instead — see the
[reference](/developers/reference#public-data-without-a-token).)

## Personal access tokens

A personal access token (PAT) acts as the member who created it, limited to
the permissions ("scopes") they picked.

* Create one at [vutuv.de/access_tokens](/access_tokens) (you need a vutuv
  account, logged in).
* The token starts with `vutuv_pat_` and is shown **exactly once**. vutuv
  stores only a hash; a lost token cannot be recovered, only replaced.
* Every token expires — after 30, 90 (default) or 365 days. The expiry
  limits the damage if a token leaks; you can always revoke earlier and
  mint a fresh one in seconds.
* Revocation is one click on the same page — per token, or all at once. A
  revoked token fails on its very next request.

Treat tokens like passwords:

* Never commit them. Pass them via environment variables:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
curl -H "Authorization: Bearer $VUTUV_TOKEN" https://vutuv.de/api/2.0/me
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
const res = await fetch("https://vutuv.de/api/2.0/me", {
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
    "https://vutuv.de/api/2.0/me",
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

## OAuth 2 for third-party apps

Personal access tokens are for your own scripts — the member has to create
and paste the token. A real third-party app uses **OAuth 2 (authorization
code + PKCE)** instead: your users click "Connect with vutuv", approve the
permissions on a consent screen, and your app receives tokens. Members see
and revoke the connection at [vutuv.de/connected_apps](/connected_apps).

### 1. Register your application

At [vutuv.de/developers/apps](/developers/apps) (you need a vutuv account —
that account is the accountability anchor; misbehaving apps get suspended,
which cuts off all of their tokens at once). You receive a `client_id` and
a `client_secret` (shown once). Register your exact redirect URLs —
`https://` only, `http://localhost` allowed for development.

API 2.0 supports **confidential clients only**: the token exchange needs the
client secret, so a purely client-side app needs a small server-side
exchange. PKCE (S256) is required on top for every client.

### 2. Send the member to the consent screen

```text
https://vutuv.de/oauth/authorize
  ?response_type=code
  &client_id=vutuv_app_…
  &redirect_uri=https://yourapp.example/callback
  &scope=profile:read posts:write
  &state=RANDOM_OPAQUE_VALUE
  &code_challenge=BASE64URL(SHA256(code_verifier))
  &code_challenge_method=S256
```

Scopes are space-separated (the table above). Generating the PKCE pair in
bash:

```bash
code_verifier=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | basenc --base64url | tr -d '=')
```

The member logs in if needed, sees your app's name and the requested
permissions in plain language, and approves or denies. You get redirected
to your exact registered `redirect_uri`:

```text
https://yourapp.example/callback?code=vutuv_ac_…&state=RANDOM_OPAQUE_VALUE
# or, on deny: ?error=access_denied&state=…
```

Always verify `state` matches what you sent.

### 3. Exchange the code for tokens

Within 10 minutes, server-side (form-encoded POST):

```bash
curl -X POST https://vutuv.de/oauth/token \
  -d grant_type=authorization_code \
  -d client_id=vutuv_app_… \
  -d client_secret=vutuv_sec_… \
  -d code=vutuv_ac_… \
  -d redirect_uri=https://yourapp.example/callback \
  -d code_verifier=$code_verifier
```

```json
{
  "access_token": "vutuv_at_…",
  "refresh_token": "vutuv_rt_…",
  "token_type": "Bearer",
  "expires_in": 7200,
  "scope": "profile:read posts:write"
}
```

The access token works exactly like a personal access token
(`Authorization: Bearer …`), acting as the consenting member with the
granted scopes. Codes are **one-time**: redeeming a code twice revokes
every token of that authorization (the standard theft response).

### 4. Refresh

Access tokens live 2 hours. Refresh tokens live 90 days and **rotate on
every use** — store the new pair, discard the old one. Using an old
(rotated) refresh token revokes the whole authorization: that, too, is
theft detection, not flakiness.

```bash
curl -X POST https://vutuv.de/oauth/token \
  -d grant_type=refresh_token \
  -d client_id=vutuv_app_… \
  -d client_secret=vutuv_sec_… \
  -d refresh_token=vutuv_rt_…
```

### 5. Revoke (RFC 7009)

When a user disconnects inside your app, throw the tokens away properly:

```bash
curl -X POST https://vutuv.de/oauth/revoke \
  -d client_id=vutuv_app_… \
  -d client_secret=vutuv_sec_… \
  -d token=vutuv_rt_…
```

Revoking a refresh token kills the whole pair. Members can do the same
unilaterally at any time on their Connected apps page — handle `401`s
gracefully, they are a normal part of life.

### Token endpoint errors

RFC 6749 vocabulary: `{"error": "invalid_client"}` with `401` for bad
client credentials, `{"error": "invalid_grant"}` with `400` for a bad/used
code, failed PKCE, redirect mismatch or a dead refresh token, and
`{"error": "unsupported_grant_type"}` for anything but the two grant
types above.
