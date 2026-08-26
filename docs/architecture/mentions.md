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

What counts is decided by the **host**, not by the shape (issue #1560).
`@ada` and `@ada@vutuv.de` name the same member: the second is the address
written out in full, which is how every remote server writes a mention of one of
us, so both are a mention and both link to the profile. Only the host is asked,
through `Vutuv.Fediverse.local_host?/1`, so the `www.` alias, a port and a
shouted spelling all count as us. An address on any **other** host is somebody
else's account and is never touched; `@php@tags.vutuv.de` is a topic of ours and
joins `hashtags/1` instead (issue #1330); a handle inside a code span/block is
sample text, not a mention (matching what the renderer links).

Before that, `local_handles/1` dropped every `@user@host` hit by design, and the
renderer sent an address on our own host to `https://vutuv.de/@ada` — the
Mastodon-web convention applied to a host that is not Mastodon, a path vutuv
does not serve. So the one clickable thing in a sentence naming a member 404ed
on our own domain, being named that way notified nobody, and a rename left the
address behind pointing at a handle its owner had given up.

## Which form is shown where

Both spellings mean the same account, and each is right exactly where it was
written. On a vutuv page the reader is already on the host the address names, so
writing it out says nothing; on mastodon.social a bare `@ada` names *their*
member of that name, who is somebody else entirely. So neither spelling is
stored — the form is chosen at render time, per surface:

| Surface | `@ada` becomes | `@ada@vutuv.de` becomes |
|---|---|---|
| a vutuv page, a plain-text quote, the tab teaser | `@ada` | `@ada` |
| the Note that federates the post | `@ada@vutuv.de` | `@ada@vutuv.de` |

`VutuvWeb.Markdown` shortens by default (`mention_form: :local`) and spells out
for `VutuvWeb.Fediverse.Docs`, which passes `mention_form: :address`; the
surfaces that flatten a body to text instead of rendering it go through
`Mentions.to_local_form/1`. Only resolved accounts are expanded, because only
they are accounts — a stray `@word` is left as written, and an address nobody
holds is shortened without becoming a link.

One thing the shortening steps over: a **URL**. The entity grammar reads a full
address after a slash on purpose (German prose writes
`Bündnis 90/@gruenebundestag@gruene.social` and means that account), and
`https://mastodon.social/@ada@vutuv.de` wears the same shape without being a
mention — it is Mastodon's web path to a remote profile, and shortened it would
read `https://mastodon.social/@ada`, naming *their* member of that name. The
renderer is safe without a guard, because the autolinker has made the URL an
`<a>` before the entity pass runs and that pass skips anchors; the plain-text
route has no anchor to skip, so `to_local_form/1` splits URLs out first.

The stored body keeps whatever was typed, so the same row reads correctly in
both places and a member who wrote one form never finds the other saved over it.
It is still shown verbatim in one place, deliberately: `body_markdown` in the
agent-format siblings is the post's Markdown source, not a rendering of it.

The outgoing Note also carries a `Mention` **tag** per account of ours the body
names — actor URI plus `@handle@host` — which is what makes the receiving server
resolve the account and draw a mention rather than a bare link. Minting one from
typed text is safe *here only*, because every handle is resolved against our own
tables; an address on somebody else's server is nobody we have checked, so it is
left to the reader's own server (see [fediverse.md](fediverse.md)). An account
that keeps out of the Fediverse serves no actor document, so it is named in the
text and left out of the tags.

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

- Detection skips code spans/blocks, emails and other servers' addresses, and
  matches whole handles (so `@old` is not found inside `@older`).
- Because the full address counts, a post naming `@nobody@vutuv.de` is refused
  exactly like one naming `@nobody`. That is the same rule, not a new one: the
  reservation attack works through either spelling, since `used_in_content?/1`
  reads the same `local_handles/1`.
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

- Counted **after the dedupe**, so naming one person five times is one account —
  and `@ada` beside `@ada@vutuv.de` is still one account.
- Addresses on another server and handles in code spans don't count — nothing
  here is notified by either.
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
   all surfaces — including `@old@vutuv.de`, which becomes `@new@vutuv.de` with
   the host kept as the author spelled it — via `Ecto.Changeset.change/2`,
   bypassing each schema's changeset, so a body's other now-dead mentions never
   block the rewrite,
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
- `test/vutuv/mentions_test.exs`, `mentions_local_address_test.exs`,
  `vutuv_web/markdown_local_address_test.exs`, `vutuv_web/mention_form_test.exs`,
  `mention_existence_test.exs`,
  `mention_limit_test.exs`,
  `mention_notifications_test.exs`, `handle_availability_test.exs`,
  `accounts/handle_change_propagation_test.exs`,
  `vutuv_web/live/handle_change_notification_test.exs`.
