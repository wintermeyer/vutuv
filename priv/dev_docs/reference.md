# API reference

Base URL: `https://vutuv.de/api/2.0` · All endpoints need a
[bearer token](/developers/authentication) · Errors are
`application/problem+json` ([details](/developers/authentication#errors)).

Conventions:

* Responses carry `schema_version` (currently `1`) where they mirror a
  public page. New fields appear without notice — parse leniently and
  ignore keys you do not know. Fields never disappear or change meaning
  within `/api/2.0`.
* Request bodies are plain JSON objects (`Content-Type: application/json`),
  no envelope.
* Reads return **what the authorizing member sees on the website** — the
  same visibility rules, enforced server-side. `404` covers both "does not
  exist" and "not visible to you".
* Validation failures are `422` with per-field messages:
  `{"errors": {"organization": ["can't be blank"]}}`.
* List endpoints with a `next_cursor` paginate by cursor: pass the value
  back as `?cursor=`, unmodified (it is signed; a tampered cursor is a
  `400`). `?limit=` accepts 1–100.
* `PUT`/`DELETE` switches (follow, like, bookmark, repost) are idempotent:
  repeating a call is success, not a conflict.

In the examples, `$VUTUV_TOKEN` holds your token and `$API` stands for
`https://vutuv.de/api/2.0`:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
export API="https://vutuv.de/api/2.0"
auth() { curl -sS -H "Authorization: Bearer $VUTUV_TOKEN" "$@"; }
```

## Profile

### GET /me · GET /users/:username

Scope: `profile:read`. Your own profile (through your own eyes: private
email addresses included) — or another member's, where you see exactly what
their profile page would show you. `noindex?`/`noai?` are the member's
consent flags — **skip members with `"noai?": true`** if you feed profiles
into an LLM.

```bash
auth $API/me
auth $API/users/wintermeyer
```

```json
{
  "type": "profile",
  "schema_version": 1,
  "name": "Stefan Wintermeyer",
  "username": "wintermeyer",
  "headline_markdown": "Phoenix, Elixir & web performance.",
  "counts": {"followers": 1208, "following": 341, "connections": 86, "posts": 412},
  "emails": [{"id": "0190…", "type": "Work", "value": "stefan@example.com"}],
  "tags": [{"id": "0190…", "name": "Phoenix", "slug": "phoenix", "endorsements": 31}],
  "work_experiences": [{"id": "0190…", "title": "Consultant", "organization": "Wintermeyer Consulting", "start": "2010-01", "end": null}],
  "links": [{"id": "0190…", "url": "https://www.wintermeyer-consulting.de", "description": "Company"}],
  "noindex?": false,
  "noai?": false,
  "...": "..."
}
```

### PATCH /me

Scope: `profile:write`. Updates the plain profile fields: `headline`,
`first_name`, `middle_name`, `last_name`, `nickname`, `honorific_prefix`,
`honorific_suffix`, `gender`, `birthdate` (ISO date), `locale`,
`noindex?` (search-engine opt-out), `noai?` (AI/LLM opt-out). Returns the
fresh profile. The username and email addresses are deliberately **not**
writable over the API.

```bash
auth -X PATCH $API/me \
  -H "Content-Type: application/json" \
  -d '{"headline": "Now hiring!", "locale": "de"}'
```

## Profile sections

Sections: `work_experiences`, `links`, `social_media_accounts`,
`addresses`, `phone_numbers`, `languages`, `emails` (read-only), `tags`.

### GET /users/:username/&lt;section&gt;

Scope: `profile:read`. The section's entries (the same shape as the public
`/username/<section>.json` pages, plus entry `id`s). The email list is
viewer-dependent: public addresses, or all of them when you are the owner
or the owner follows you.

```bash
auth $API/users/wintermeyer/work_experiences
```

### POST /me/&lt;section&gt; · PATCH /me/&lt;section&gt;/:id · DELETE /me/&lt;section&gt;/:id

Scope: `profile:write`. Create, edit, delete your own entries (not for
`emails` — an address is a PIN-verified identity and can only be managed
on the website). Create and update answer with the entry's document (the
fields under `entry`, plus the canonical URL of its public page); delete
answers `204`.

```bash
auth -X POST $API/me/work_experiences \
  -H "Content-Type: application/json" \
  -d '{"title": "Developer", "organization": "ACME", "start_year": 2024, "start_month": 3}'

auth -X PATCH $API/me/work_experiences/0190abcd-… \
  -H "Content-Type: application/json" \
  -d '{"title": "Senior Developer"}'

auth -X DELETE $API/me/work_experiences/0190abcd-…
```

Field names per section: work_experiences (`title`, `organization`,
`description`, `kind` = `employment`/`internship`/`volunteer` (default
`employment`), `start_year`, `start_month`, `end_year`, `end_month`),
links (`value` = the URL, `description`), social_media_accounts
(`provider`, `value`), addresses (`description`, `line_1`…`line_4`,
`zip_code`, `city`, `state`, `country`), phone_numbers (`value`,
`number_type`), languages (`language_code` = an ISO 639-1 code such as
`en`/`de`, `proficiency` = `native` or a CEFR level `a1`…`c2`).
`number_type` must be one of `Work`, `Cell`, `Home`, `Fax`
(case-sensitive); any other value is rejected with `422`.

### POST /me/tags · DELETE /me/tags/:id

Scope: `profile:write`. Tags are global; adding one links or creates it.

```bash
auth -X POST $API/me/tags -H "Content-Type: application/json" -d '{"name": "Phoenix"}'
auth -X DELETE $API/me/tags/0190abcd-…
```

## Social graph

### GET /users/:username/followers · /following · /connections

Scope: `social:read`. The people lists (same doc shape as the public
`.json` pages; followers/following paginate with `?page=N`).

### GET /users/:username/relationship

Scope: `social:read`. Your standing with that member — what the profile
header shows you:

```bash
auth $API/users/wintermeyer/relationship
```

```json
{
  "type": "relationship",
  "self": false,
  "following": true,
  "followed_by": false,
  "connected": false
}
```

`connected` is `true` only when you follow each other (vernetzt). Asking
about yourself answers `{"type": "relationship", "self": true, ...}` with no
flags.

### PUT /users/:username/follow · DELETE /users/:username/follow

Scope: `social:write`. Follow (idempotent; `201` on a new follow, `200`
when already following) and unfollow (`204`; `404` when not following).
A block between the accounts answers `403`.

```bash
auth -X PUT $API/users/wintermeyer/follow
auth -X DELETE $API/users/wintermeyer/follow
```

### Connections (vernetzt) and muting

A connection is not a separate object and has no endpoints of its own: two
members are connected ("vernetzt") exactly when they **follow each other**.
Follow someone who already follows you, or who later follows back, and you
are connected; either side unfollowing ends it. The `relationship` response
reports it as `connected`, and `GET /users/:username/connections` lists a
member's mutual follows.

Scope `social:write`. A follow you own can be **muted** without unfollowing,
which keeps the connection but drops that member's posts from your feed:

```bash
auth -X PUT $API/follows/0190…/mute   # toggles muted on a follow you own
```

## Posts

### GET /posts/:id

Scope: `posts:read`. The permalink doc — body, tags, images, the reply
list you are allowed to see.

### GET /users/:username/posts

Scope: `posts:read`. The author archive (posts + reposts, `?page=N`),
entries with `id`, `url`, `excerpt`, `reposted_by`.

### GET /feed

Scope: `posts:read`. Your timeline (your posts + followed authors' posts
and reposts), newest first, cursor-paginated:

```bash
auth "$API/feed?limit=25"
auth "$API/feed?cursor=NEXT_CURSOR_FROM_LAST_PAGE"
```

```json
{
  "type": "feed",
  "posts": [{"id": "0190…", "url": "…", "published_on": "2026-06-12",
             "author": {"name": "…", "username": "…", "url": "…"},
             "body_markdown": "…", "tags": [],
             "reposted_by": {"name": "…", "username": "…", "url": "…"}}],
  "more": true,
  "next_cursor": "SFMyNTY…"
}
```

### POST /posts

Scope: `posts:write`. Fields: `body` (Markdown, required unless images),
`tags` (comma-separated string or list), `denials` (audience
restrictions, see below), `image_ids` (uploaded images, see below).

```bash
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello from the API!", "tags": "elixir, phoenix"}'
```

Audiences are **deny-based**: no `denials` means public. Each denial is
one of `{"wildcard": "non_connections" | "non_followers" | "non_followees"
| "logged_out" | "everyone"}` or `{"denied_user_id": "<user id>"}`, with
semantics in
[the data model](/developers/data-model#audiences-the-denial-model).
A connections-only post:

```bash
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Connections only", "denials": [{"wildcard": "non_connections"}]}'
```

### POST /me/post_images

Scope: `posts:write`. Upload an image (multipart, the file in the
`image` field, optional `alt`), then attach it via `image_ids`:

```bash
IMAGE_ID=$(auth -X POST $API/me/post_images \
  -F "image=@photo.jpg" -F "alt=Sunrise over Koblenz" | jq -r .id)

auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d "{\"body\": \"What a morning!\", \"image_ids\": [\"$IMAGE_ID\"]}"
```

JPEG/PNG/WebP, at most 6 MB, up to 10 per post. An uploaded image that is
not attached to a post within 24 hours is swept;
`DELETE /me/post_images/:id` removes a pending upload immediately. Served
image bytes always go through the audience-checking proxy, like on the
website.

### PATCH /posts/:id · DELETE /posts/:id

Scope: `posts:write`, own posts only. While reposts or replies exist the
audience cannot be restricted (`409`, `reason: visibility_locked`);
deleting is always possible (`204`).

### POST /posts/:id/replies

Scope: `posts:write`. A reply is a normal post (same fields) attached to a
**public** parent; a restricted parent answers `409`
(`reason: restricted`).

### PUT/DELETE /posts/:id/like · /bookmark · /repost

Scope: `posts:write`. Idempotent switches; each answers the fresh
engagement state. Reposting works on public posts only (`409` otherwise);
likes across a block answer `403`.

```bash
auth -X PUT $API/posts/0190…/like
```

```json
{"type": "post_engagement", "post_id": "0190…", "likes": 12, "bookmarks": 3,
 "reposts": 2, "replies": 4, "liked?": true, "bookmarked?": false,
 "reposted?": false}
```

### GET /posts/:id/engagement

Scope: `posts:read`. The same engagement state, read-only.

## Messages

The message-request model applies, exactly as on the website: your message
lands directly when the recipient already follows you; otherwise it opens
a **request** with exactly one message, which the recipient accepts or
declines. Declining is silent. New requests are rate-limited.

### GET /conversations

Scope: `messages:read`. Your accepted conversations and own outgoing
requests under `conversations`, incoming requests under `requests` — each
with the other member, a preview, `last_message_at` and your `unread`
count.

### GET /conversations/:id/messages

Scope: `messages:read`. The thread, newest first, cursor-paginated.

```bash
auth "$API/conversations/0190…/messages?limit=30"
```

### POST /users/:username/messages · POST /conversations/:id/messages

Scope: `messages:write`. Send by member (finds or opens the conversation)
or into a known conversation. Markdown body.

```bash
auth -X POST $API/users/wintermeyer/messages \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello Stefan!"}'
```

Answers `201` with the message. A second message into your own pending
request is `409` (`reason: pending_limit`); a member who cannot receive
messages answers `403`; too many new requests answer `429`.

### POST /conversations/:id/accept · /decline · /read

Scope: `messages:write`. Answer an incoming request; `/read` clears your
unread marker (`204`).

## Notifications

### GET /api/2.0/notifications · POST /api/2.0/notifications/read

Scopes: `social:read` / `social:write`. The derived notification feed
(new follower, endorsement, connection events, replies, likes, moderation
notices), cursor-paginated, plus your unread count; `/read` moves the read
marker (`204`).

```bash
auth $API/notifications
```

```json
{
  "type": "notifications",
  "unread": 2,
  "notifications": [{"id": "follower-0190…", "kind": "follower",
                     "actor_name": "Greta Tester", "actor_username": "greta-tester",
                     "at": "2026-06-11T14:00:00"}],
  "more": false,
  "next_cursor": null
}
```

## Public data, without a token

Anonymous public reads do not need the API at all: every public page is
also served as `.json` (and `.md`, `.txt`, the profile as `.vcf`) under
its own URL — the anonymous view, cache-friendly, no auth:

```bash
curl https://vutuv.de/wintermeyer.json            # profile
curl https://vutuv.de/wintermeyer/posts.json      # post archive
curl https://vutuv.de/tags/phoenix.json                  # a tag page
```

The full page list lives in [`/llms.txt`](/llms.txt).

## CORS

`/api/2.0` sends `Access-Control-Allow-Origin: *` — browser apps can call
it directly. Never embed a long-lived token in shipped client code; tokens
belong server-side or in the user's own hands.

## Versioning promise

* Additive changes (new endpoints, new fields) happen within `/api/2.0`.
* Breaking changes (removed/renamed fields, changed semantics) only happen
  in a new version prefix, with a documented migration window.
* The old read-only `/api/1.0` JSON-API has been removed; this API
  replaces it.

## See also

[Authentication & tokens](/developers/authentication) (PATs, OAuth 2,
scopes, errors, rate limits), the [cookbook](/developers/cookbook)
(task-by-task recipes), [the data model](/developers/data-model) (what the
entities mean and who sees what) and [Webhooks](/developers/webhooks)
(signed event deliveries instead of polling). This reference only ever
documents what is actually live.
