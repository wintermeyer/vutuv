# Mentions & handle changes

How `@handle` mentions work, why claiming and reserving a handle are both
locked down, and what happens to stored mentions when a member renames.

A mention is **plain text** `@handle` inside a Markdown body — nothing
structured is stored. `VutuvWeb.Markdown` turns it into a profile link only at
**render time**, by looking the handle up in the database. So the same text can
mean different people over time, and four concerns have to agree on *what
counts as a mention*: rendering, existence validation, rename propagation and
the notification below. They share one definition in **`Vutuv.Mentions`**,
which owns the entity grammar (`entity_regex/0`, read back by
`VutuvWeb.Markdown` so the renderer can never drift from it).

Only the **local** `@handle` form is a vutuv handle. A fediverse `@user@host`
handle and a `#hashtag` are never touched, and a handle inside a code span/block
is sample text, not a mention (matching what the renderer links).

## The mention surfaces

Every field whose stored `@handle` linkifies is one `{schema, field}` entry in
`Vutuv.Mentions.surfaces/0`, the single list the rewrite reads:

| Surface | Field |
|---|---|
| `posts` | `body` |
| `messages` | `body` |
| `users` | `headline` |
| `work_experiences` | `description` |
| `educations` | `description` |
| `job_postings` | `description` |
| `ads` | `content` |

## Existence validation (anti-reservation)

Every one of those changesets runs `Mentions.validate_mentions_exist/2`: a saved
body may only mention handles that **exist** (a member or organization holds
them). Without it, a bad actor could seed `@wanted` into a post to *reserve* it
— the availability rule below would then treat `@wanted` as "used in a post" and
block everyone, forever.

- Detection skips code spans/blocks, emails and fediverse handles, and matches
  whole handles (so `@old` is not found inside `@older`).
- Detection **sees through a Markdown escape** inside a handle. The Milkdown
  WYSIWYG editor serializes `@ulrich_wolf` as `@ulrich\_wolf` (remark escapes the
  `_`, a Markdown emphasis char). Earmark undoes that before the renderer links
  the mention, so a post renders fine — but `Vutuv.Mentions` reads the raw
  **source**, where the stray backslash used to truncate the handle to the
  non-existent `@ulrich` and reject a real member. `unescape_handle_chars/1`
  drops the escape before scanning; the editor also stores the bare handle
  (`assets/js/markdown_editor.js` `canonicalizeMentions`, backfilled by the
  `RepairMilkdownEscapedMentions` migration), so the source stays canonical too.
- The check runs only when the field actually **changed**; editing an old body
  with a since-dead mention is not forced to clean up unless you touch it.
- The bulk **LinkedIn import** carries arbitrary external prose ("Managed the
  @Acme account"), so `apply_selection/2` wraps its transaction in
  `Mentions.without_existence_check/1` — otherwise a stray `@token` would
  silently drop the row.

## Being mentioned is a notification

A post that names you is news, wherever it sits. `Vutuv.Posts` resolves a saved
body through `Mentions.mentioned_users/2` and reconciles one `post_mentions`
row per named member; `Vutuv.Activity` reads that table as the feed's
`"mention"` kind. Why the row exists at all, what the write and read sides each
filter out, and the `reply` > `mention` > `thread` precedence are in
[realtime.md](realtime.md) — the short version is that an ILIKE over every post
on every unread count was not an option, so the scan happens once at save time.

Only **members** are resolved. Organizations hold handles in the same namespace
and the renderer links them, but they have no notification feed, so `@acme_gmbh`
records nothing.

## Availability (anti-hijack)

A handle is only claimable if `Mentions.mentioned_in_posts?/1` is false — it is
**used in no post**. Claiming a handle already linked from a post would silently
capture those existing links. It is enforced on every handle claim:

- member rename (`User.username_changeset/2`),
- registration and organization auto-generation (`SlugHelpers.gen_handle_unique/4`
  treats a post-mentioned handle like a collision and adds the short-sha suffix,
  so signup never *fails* on it),
- organization handle claim (`Organization.handle_changeset/2`),
- the live availability endpoint.

Scoped to **posts** (public content) on purpose: a private DM must not make a
handle globally unclaimable. The scan narrows with `body ILIKE '%@handle%'`
(backed by a `pg_trgm` GIN index on `posts.body`) and then verifies each
candidate precisely.

## Rename propagation

`Accounts.update_username/2` does the rename in one `Ecto.Multi`:

1. update the user + move the `handles` registry row + write the
   `username_changes` ledger row (unchanged),
2. `Mentions.rewrite_everywhere/3` rewrites every stored `@old` to `@new` across
   all surfaces — via `Ecto.Changeset.change/2`, bypassing each schema's
   changeset, so a body's other now-dead mentions never block the rewrite,
3. file one `handle_change_notifications` row per **other** author whose posts
   were rewritten (the renamer's own posts are rewritten but never
   self-notified), with the ids of *their* affected posts.

All in the transaction, so the rename is all-or-nothing. On commit the affected
authors get a live push (`Activity.notify_handle_change/2`); the form flashes how
many posts were updated. Renames are rate-limited (4 / 90 days), so this stays a
rare, bounded write — and having rewritten `@old` out of every post, freeing it
is safe.

## The notification

`handle_change_notifications` is, with `post_mentions` above, one of **two**
notification kinds with their own table. The rest of the
[notifications feed](realtime.md) is derived from current-state tables at read
time, but "@old → @new" is a point-in-time fact the
current state can't reconstruct, so it is persisted (recipient, actor, old +
new handle, the affected `post_ids`). `Vutuv.Activity` reads it like any other
source (`handle_change_items/3`, `count_handle_changes/2`, a `latest_event_at`
arm), so it counts toward the unread badge and survives a reload. The
notifications LiveView shows the before/after handles and links the rewritten
posts (the newest five, plus an "and N more" count).

## Key files & tests

- `lib/vutuv/mentions.ex` — the chokepoint (grammar, rewrite, validation, scan,
  `mentioned_users/2`).
- `lib/vutuv/posts.ex` — `sync_mentions/1`, the `post_mentions` reconcile.
- `lib/vutuv/posts/post_mention.ex` — the resolved index row.
- `lib/vutuv/activity.ex` — `mention_events/1` + the `"mention"` feed source.
- `lib/vutuv/accounts.ex` — `update_username/2` + notification creation.
- `lib/vutuv/accounts/handle_change_notification.ex` — the durable row.
- `lib/vutuv_web/live/notification_live/index.ex` — the `mention` and
  `handle_change` renderings.
- `test/vutuv/mentions_test.exs`, `mention_existence_test.exs`,
  `mention_notifications_test.exs`, `handle_availability_test.exs`,
  `accounts/handle_change_propagation_test.exs`,
  `vutuv_web/live/handle_change_notification_test.exs`.
