# The data model

What the entities behind the API mean, how they relate, and the rules that
govern who sees what. Endpoint-by-endpoint details live in the
[reference](/developers/reference); runnable examples in the
[cookbook](/developers/cookbook).

## The big picture

```text
member ─┬─ profile sections: emails, links, social media accounts,
        │    addresses, phone numbers, work experiences
        ├─ member tags ── endorsements (given by other members)
        │      └─ global tag
        ├─ posts ─┬─ denials (audience restrictions)
        │         ├─ images
        │         ├─ replies (posts themselves)
        │         └─ likes · bookmarks · reposts
        ├─ follows → member          (one-directional subscription)
        ├─ connections ↔ member      (derived: a mutual follow)
        ├─ groups (of followers)     (custom audiences for posts)
        └─ conversations ── messages (direct messages, request model)
```

## Members

The central entity. A member (`type: "profile"` in API responses) has:

* **Identity:** `name` (assembled), `first_name`, `middle_name`,
  `last_name`, `nickname`, `honorific_prefix`/`_suffix`, `gender`,
  `birthdate`, `locale`.
* **The username** (`username`, e.g. `wintermeyer`): unique, the
  profile URL (`vutuv.de/<username>`) and the `:username` in every API path.
  Changeable on the website only; old usernames are released, not redirected.
* **`headline_markdown`:** the one-liner under the name, Markdown.
* **`verified`:** `true` when vutuv has verified the member's identity
  against a physical ID document. A trust signal — treat unverified
  profiles accordingly.
* **`counts`:** `followers`, `following`, `connections`, `posts`.
* **Consent flags:** `noindex?` (member opted out of search engines) and
  `noai?` (member opted out of AI/LLM processing) — readable on API
  profile responses and writable on your own profile via `PATCH /me`.
  **Honor these**: if your app feeds profiles into an LLM, skip members
  with `"noai?": true`. (The public `.json`/`.md` pages carry the same
  choice as `Content-Signal` and `X-Robots-Tag` response headers.)
* **`member_since`:** the registration date.

A member who never verified their email address, or who is currently
moderated, is invisible through the API — see
[Visibility](#visibility-through-the-members-eyes).

## Profile sections

Each section is a list of entries belonging to one member. All of them are
readable via `GET /users/:username/<section>` and (except emails) writable on
your own profile via `POST/PATCH/DELETE /me/<section>`:

| Section | Entry fields | Notes |
|---------|-------------|-------|
| `emails` | `id`, `type` (`Work`/`Personal`/`Other`), `value` | Read-only over the API: an address is a PIN-verified login identity. Members mark addresses public or private; private ones are visible only to the owner. |
| `links` | `value` (URL), `description` | vutuv renders a screenshot preview on the website. |
| `social_media_accounts` | `provider`, `value` (handle) | Providers: Facebook, Twitter, Instagram, YouTube, Snapchat, LinkedIn, XING, GitHub. |
| `addresses` | `description`, `line_1`…`line_4`, `zip_code`, `city`, `state`, `country` | |
| `phone_numbers` | `value`, `number_type` | Read responses return the type as `type`; writes take `number_type`. |
| `work_experiences` | `title`, `organization`, `description`, `kind`, `start_year`, `start_month`, `end_year`, `end_month` | `kind` files the entry as `employment` (default), `internship` or `volunteer`. An open `end` means "current position"; the most recent current one feeds the profile's `current_position`. |

Entry `id`s are stable — store them to update or delete later.

## Tags and endorsements

* A **tag** is global: one record per topic (`name` + URL `slug`,
  e.g. `Phoenix` → `/tags/phoenix`), shared by everyone who claims it.
* A **member tag** links a member to a tag ("Stefan claims Phoenix").
  Adding a tag to your profile (`POST /me/tags`) links the existing global
  tag or creates it on the fly.
* An **endorsement** is one member vouching for another member's tag.
  Each member can endorse a given member-tag once. The `endorsements`
  count on a profile's tag entries is the member's credibility signal for
  that topic; profile tags sort by it.

## The social graph: follows and connections

Follow is the only relationship primitive:

* A **follow** is one-directional and needs no consent (Twitter-style).
  Following someone puts their posts into your feed. Idempotent
  `PUT`/`DELETE /users/:username/follow`. A follow can be **muted**
  (`PUT /follows/:id/mute`), which keeps the relationship but drops that
  person's posts from your feed.
* A **connection** ("vernetzt") is not a separate record: two members are
  connected exactly when they **follow each other**. There is no request,
  accept or decline step. A follow-back is what makes a pair connected, and
  either side unfollowing ends it.

`GET /users/:username/relationship` answers your complete standing with one
member: `following`, `followed_by` and `connected` (the mutual-follow flag).

A member can also **block** another — deliberately opaque to the other
side; see [Visibility](#visibility-through-the-members-eyes).

**Groups** are private, custom lists of members you follow ("colleagues",
"customers"). They exist for one purpose: as building blocks for post
audiences. Nobody but you sees your groups; they are managed on the
website.

## Posts

A post is Markdown `body_markdown` (up to 20,000 characters), optional
**tags** (the same global tags as on profiles), optional **images**, and an
optional **audience**. Posts have a permalink
(`/<username>/posts/<id>`), appear in the author's archive and in their
followers' feeds.

### Audiences: the denial model

Visibility is **deny-based**: a post with no denials is public. Each
denial excludes one set of readers, and a reader matching *any* denial is
excluded (union). Denial shapes:

* `{"wildcard": "logged_out"}` — only logged-in members see it.
* `{"wildcard": "non_followers"}` — only your followers.
* `{"wildcard": "non_followees"}` — only members you follow.
* `{"wildcard": "non_connections"}` — only your connections.
* `{"wildcard": "everyone"}` — only you (a private note).
* `{"denied_user_id": "<member id>"}` — everyone but this member.

Once a post has replies or reposts, its audience can no longer be
restricted (`409`, `reason: visibility_locked`) — people who interacted
with a public post must not lose the context. Deleting is always possible.

### Replies, likes, bookmarks, reposts

* A **reply** is a regular post (same fields, own permalink) attached to a
  **public** parent post; restricted posts cannot be replied to. The link
  to the parent survives even if the parent is deleted later.
* **Like**, **bookmark** and **repost** are idempotent per-member switches
  (`PUT` = on, `DELETE` = off). A repost pushes the post into your
  followers' feeds (`reposted_by` on the feed entry); it works on public
  posts only. Bookmarks are private to you.

### Images

Images are uploaded first (`POST /me/post_images`, multipart), then
attached to a post via `image_ids`. JPEG/PNG/WebP in, at most 6 MB and 10
per post; vutuv converts to AVIF and strips metadata. Image URLs go
through an audience-checking proxy: a restricted post's images are exactly
as restricted as the post. Unattached uploads are swept after 24 hours.

## Direct messages

Messaging follows a **request model** that protects members from cold-DM
spam:

* A **conversation** connects exactly two members and holds their
  **messages** (Markdown, up to 10,000 characters each).
* If the recipient **follows you**, your message lands directly in an
  accepted conversation.
* Otherwise your first message opens a **request**: the recipient sees it
  under `requests` and accepts or declines. Until they accept, you cannot
  send a second message (`409`, `reason: pending_limit`). Declining is
  silent — the sender keeps seeing a pending request. New requests are
  rate-limited per sender.
* Each side has its own **unread** counter; `POST /conversations/:id/read`
  clears yours.

## Notifications

A derived, read-only feed of what happened to *you*: new followers,
endorsements, new connections (a follow-back made you vernetzt), replies,
likes, and moderation notices. Entries carry a `kind`, the acting member and a
timestamp. The `unread` count matches the bell icon on the website;
`POST /notifications/read` moves your read marker. Webhook-capable apps
get most of this pushed instead — see [webhooks](/developers/webhooks).

## Visibility: through the member's eyes

The one rule that explains most `404`s: **every read returns exactly what
the authorizing member would see on the website.** Visibility is enforced
server-side, per request:

* Profiles hidden by moderation (frozen, suspended, deactivated) or never
  activated: `404`.
* Posts: the denial model above, evaluated against the viewer.
* Emails: public addresses only, unless you are the owner.
* Blocks: opaque — `403` or `404` without naming the reason.
* "Does not exist" and "not visible to you" are deliberately
  indistinguishable.

## Ids, ordering, pagination

* Every id is a **UUID v7** — it embeds its creation timestamp, so ids
  sort by creation time. Treat them as opaque strings.
* List endpoints paginate one of two ways: **cursor** (feed, messages,
  notifications — pass `next_cursor` back as `?cursor=`, unmodified, until
  `more` is `false`; `?limit=` accepts 1–100) or **pages**
  (followers/following and other browse lists — `?page=N`).
* Responses that mirror a public page carry `schema_version` (currently
  `1`). New fields appear without notice: parse leniently, ignore unknown
  keys. Fields never disappear or change meaning within `/api/2.0`.
