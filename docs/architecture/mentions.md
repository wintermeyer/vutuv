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

**An organization handle is a real mention** (#1336), not merely a valid one.
For a long while validation accepted it — members and pages share one handle
namespace — while the renderer looked handles up among members only, so `@acme`
saved and then rendered as plain text: accepted as real and drawn as if it were
not. It links to the page now, with the page's name as the `title`, and
`Mentions.mentioned_organizations/1` resolves the page side while
`mentioned_users/2` resolves the member side. The two never overlap, because a
handle belongs to at most one of them; members win the merge anyway, since a
person's profile is the destination you do not want to get wrong. A page nobody
may see (pending, frozen, archived) is deliberately **not** linked — the text
stays readable, but no link leads where the reader would be turned away.

Such a mention is recorded: `post_mentions` carries `user_id | organization_id`
(CHECK exactly one), and the page's own `/organizations/:slug/activity` list
reads it. The rows are a reconciled index of the body, so editing the mention
out takes the entry with it, and a page naming *itself* is not news to its own
team.

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
- A **fediverse handle round-tripped the same way, and worse**. GFM's autolink
  literal reads `user@host.tld` as an email, so remark parses `@php@tags.vutuv.de`
  into a `mailto:` link node and serializes it back in one of two shapes,
  depending only on which path the body took: `@<php@tags.vutuv.de>` after a
  re-parse (a draft restore, a post edit), and `@php\@tags.vutuv.de` on a first
  write. The first shipped and was reported — vutuv escapes `<` at render time,
  so the sentence read `@<php@tags.vutuv.de>` on the page. The second is the
  dangerous one here: that backslash splits **one fediverse handle into the two
  local handles** `@php` and `@tags`, so the existence check refuses to save the
  body at all ("the handle @php does not exist"), which is the `@ulrich\_wolf`
  failure again with a different escape. Both are canonicalized away by
  `canonicalizeAddresses` in the editor and backfilled by
  `RepairMilkdownEscapedAddresses`. The pattern to carry forward: **any Markdown
  syntax remark knows and vutuv does not store is a round-trip hazard**, and
  each one costs an editor transform plus a repair migration (URLs, `_` in
  handles, footnotes, now addresses).
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

## The per-post cap (anti-spam)

A post may name at most **`Mentions.max_post_mentions/0`** (5) distinct local
accounts — `Mentions.validate_mention_limit/2`, run from `Post.changeset/2`
only. Being mentioned is a notification (below), so a post that advertises
something and then lists twenty handles reaches all twenty whether they follow
the author or not: spam delivered through our own notification feed. The
changeset refuses it with a sentence naming the rule ("We allow at most 5
accounts per post. Please remove some mentions."), which the composer surfaces
like any other body error.

- Counted **after the dedupe**, so naming one person five times is one account.
- Fediverse `@user@host` handles and handles in code spans don't count —
  nothing here is notified by either.
- Like the existence check it runs only when the body **changed**, so an old
  post is not held hostage by a cap that did not exist when it was written, and
  a rename rewrite (which bypasses changesets) never trips it.
- Posts only. A DM already goes to one recipient, and the other mention
  surfaces (headline, descriptions, ads) notify nobody.

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
  `mention_limit_test.exs`,
  `mention_notifications_test.exs`, `handle_availability_test.exs`,
  `accounts/handle_change_propagation_test.exs`,
  `vutuv_web/live/handle_change_notification_test.exs`.
