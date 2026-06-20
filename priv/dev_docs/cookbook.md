# Cookbook

Concrete, copy-paste answers to "how do I …?". Every recipe is a complete,
runnable command. Once: create a [token](/developers/authentication) with the
scopes you need, then put it and a small helper into your shell:

```bash
export VUTUV_TOKEN="vutuv_pat_..."
export API="https://vutuv.de/api/2.0"
auth() { curl -sS -H "Authorization: Bearer $VUTUV_TOKEN" "$@"; }
```

(Against a local development server, set `API="http://localhost:4000/api/2.0"`.)

Details for every endpoint and field live in the
[reference](/developers/reference); what the entities mean lives in
[the data model](/developers/data-model).

## How do I read my own profile?

Scope `profile:read`:

```bash
auth $API/me
```

You get your profile as JSON — through your own eyes, so private email
addresses are included. `GET $API/users/<username>` reads anyone else's
(you see what their profile page would show you, never more).

## How do I post something?

Scope `posts:write`. The body is Markdown:

```bash
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello from the API! **Markdown** works."}'
```

The answer is `201` with the full post, including its `id` and `url`. Add
tags with a comma-separated string:

```bash
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Talk slides are up!", "tags": "elixir, phoenix"}'
```

A post is public unless you exclude readers ("denials" — see
[the data model](/developers/data-model#audiences-the-denial-model)). For a
connections-only post:

```bash
auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d '{"body": "Connections only.", "denials": [{"wildcard": "non_connections"}]}'
```

## How do I post an image?

Scope `posts:write`. Upload first (multipart), then attach by id:

```bash
IMAGE_ID=$(auth -X POST $API/me/post_images \
  -F "image=@photo.jpg" -F "alt=Sunrise over Koblenz" | jq -r .id)

auth -X POST $API/posts \
  -H "Content-Type: application/json" \
  -d "{\"body\": \"What a morning!\", \"image_ids\": [\"$IMAGE_ID\"]}"
```

Formats and limits: see [Images](/developers/data-model#images) in the
data model.

## How do I send a direct message?

Scope `messages:write`. Send to a member by their username — this finds the
existing conversation or starts a new one:

```bash
auth -X POST $API/users/wintermeyer/messages \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello Stefan! Your talk was great."}'
```

`201` with the message. Mind the **request model**: if the recipient does
not follow you yet, your first message opens a *request* that they accept
or decline — and until they accept, you cannot send a second one (`409`,
`reason: pending_limit`). If they follow you, your message lands directly.

## How do I read my direct messages?

Scope `messages:read`. First the inbox — accepted conversations (plus your
own outgoing requests) under `conversations`, incoming requests from
strangers under `requests`:

```bash
auth $API/conversations
```

```json
{
  "type": "conversations",
  "conversations": [{"id": "0190…", "status": "accepted",
                     "with": {"name": "Greta Tester", "username": "greta-tester", "url": "…"},
                     "preview": "See you there!", "last_message_at": "2026-06-12T09:30:00", "unread": 2}],
  "requests": []
}
```

Then a thread, newest first, cursor-paginated:

```bash
auth "$API/conversations/0190…/messages?limit=30"
```

Each message carries `body_markdown`, `from`, `sent_at` and `mine` (true
for the ones you sent). Afterwards, clear your unread counter:

```bash
auth -X POST $API/conversations/0190…/read
```

## How do I accept or decline a message request?

Scope `messages:write`. An entry from `requests` (above):

```bash
auth -X POST $API/conversations/0190…/accept    # talk
auth -X POST $API/conversations/0190…/decline   # silently decline
```

Declining is invisible to the sender: to them the request just stays
pending.

## How do I follow someone, and what is a connection?

Scope `social:write`. **Follow** = one-directional subscription (their
posts appear in your feed), no consent needed:

```bash
auth -X PUT $API/users/wintermeyer/follow      # follow
auth -X DELETE $API/users/wintermeyer/follow   # unfollow
```

**Connection** ("vernetzt") is not a separate action: you are connected with
someone exactly when you both follow each other. Follow them back, or have
them follow you back, and you are connected; unfollow to end it.

Where do you stand with someone? One call:

```bash
auth $API/users/wintermeyer/relationship
```

## How do I read my feed?

Scope `posts:read`. Your timeline — your posts plus posts and reposts of
everyone you follow, newest first:

```bash
auth "$API/feed?limit=25"
```

Page with the returned `next_cursor` until `more` is `false`:

```bash
auth "$API/feed?cursor=NEXT_CURSOR_FROM_LAST_PAGE"
```

## How do I reply to, like, or repost a post?

Scope `posts:write`. A reply is a normal post attached to a public parent;
like/bookmark/repost are idempotent switches (`PUT` on, `DELETE` off):

```bash
auth -X POST $API/posts/0190…/replies \
  -H "Content-Type: application/json" \
  -d '{"body": "Great point!"}'

auth -X PUT $API/posts/0190…/like
auth -X PUT $API/posts/0190…/repost
auth -X DELETE $API/posts/0190…/like
```

## How do I update my profile?

Scope `profile:write`. Plain fields via `PATCH /me`:

```bash
auth -X PATCH $API/me \
  -H "Content-Type: application/json" \
  -d '{"headline": "Phoenix & Elixir consulting. Available from August."}'
```

Section entries (work experience, links, …) via their own endpoints:

```bash
auth -X POST $API/me/work_experiences \
  -H "Content-Type: application/json" \
  -d '{"title": "Senior Developer", "organization": "ACME", "start_year": 2024, "start_month": 3}'

auth -X POST $API/me/links \
  -H "Content-Type: application/json" \
  -d '{"value": "https://example.com/blog", "description": "My blog"}'

auth -X POST $API/me/tags \
  -H "Content-Type: application/json" \
  -d '{"name": "Phoenix"}'
```

## How do I check my notifications?

Scope `social:read` — the same feed the bell icon shows (new followers,
endorsements, connection events, replies, likes):

```bash
auth $API/notifications
```

`unread` carries the count; `POST $API/notifications/read`
(scope `social:write`) moves your read marker.

## How do I read public data without any token?

Every public page is also served machine-readable under its own URL plus
`.json`, `.md` or `.txt` (profiles additionally as `.vcf`) — the anonymous
view, no account needed:

```bash
curl https://vutuv.de/wintermeyer.json        # a profile
curl https://vutuv.de/wintermeyer/posts.json  # their post archive
curl https://vutuv.de/tags/phoenix.json              # a tag page
```

The full list of public pages: [`/llms.txt`](/llms.txt).

## Something failed — now what?

Errors are JSON problem documents with a human-readable `detail` that says
what is wrong (missing scope, rate limit, validation error, …) — read it,
it is written to be read. The catalog: [errors](/developers/authentication#errors).
