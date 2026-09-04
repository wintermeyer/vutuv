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

A **Bluesky** handle is the one `@` form that answers to neither rule, because
it has no host half to ask about: `@hilwiller.bsky.social` writes the whole
account as a domain. Read by the bare form it came out as the vutuv member
`@hilwiller` followed by dead text, so a boosted post naming a Bluesky account
linked whoever holds that handle here, and a member's own post naming one was
refused with "the handle @hilwiller does not exist". The grammar therefore tries
it before the bare form and the renderer links it out to
`Vutuv.Bluesky.profile_url/1` — bsky.app, new tab, no mention card, since
Bluesky is not a network this installation can follow anybody on. Only
`*.bsky.social` counts: a handle on a custom domain looks exactly like an
ordinary word in front of an abbreviation.

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

## Writing one: the composer's picker

Until issue #1748 a mention was typed blind. You spelled the handle from
memory, and the first thing that told you whether it named anybody was the save
being refused — `Mentions.validate_mentions_exist/2` answering "The handle @x
does not exist" after the post was written. Every chat and social client has
done the other thing for a decade, and members arriving from them missed it.

The picker sits in the **shared** Markdown editor (`VutuvWeb.UI.markdown_editor/1`
and `assets/js/markdown_editor.js`), not in the post composer, so replies, the
edit form, messages, job descriptions and organization pages all got it at
once — every one of those bodies renders its mentions as links.

Two halves, both answered by `VutuvWeb.MentionController` under `/system/`:

- **`GET /system/mentions/suggest?q=`** → `Mentions.suggest/3`. Members and
  pages whose handle starts with the term or whose name contains it, followed
  accounts first (that is who you almost always mean, and a mention is a
  notification — offering the stranger first is how the wrong person gets one).
  It refuses to offer an account blocked in either direction, a member
  moderation hides or who never confirmed, a page that is not publicly visible,
  and the viewer themselves. A picker is a second way to find accounts, and one
  that answered more freely than the search page would turn a block into a
  suggestion.
- **`GET /system/mentions/check?handles=`** → `Mentions.check_handles/1`, which
  asks `resolvable_handles/1` — the very resolution `VutuvWeb.Markdown` performs
  when it turns a handle into a link. That is what lets the editor draw a
  **chip**: a resolving handle gets the pill, an invented one stays plain text.
  A chip therefore says exactly one thing — "this will be a link" — answered
  before the post is written rather than after.

  It is deliberately a **narrower** question than the save-time
  `unknown_handles/1`, which only asks whether somebody holds the handle. A page
  nobody may see holds its handle (the save takes it) and the renderer leaves it
  as text, so it gets no chip. The two directions are not equally bad: a missing
  chip on a savable handle is quiet, a chip promising a link that never appears
  is the lie the feature exists to prevent.

Nothing about the **document** changes. The picker types a bare `@handle` and
the chip is a ProseMirror inline decoration over that text, so the stored
Markdown, `VutuvWeb.Markdown`, the agent-format siblings and the federated Note
see exactly what they saw before. That is deliberate: a mention node in the
schema would be a fifth thing that has to agree about what a mention is, and
`assets/js/markdown_editor.js` already carries three transforms that exist only
because remark serializes a construct vutuv stores plainly (see the escape
hazards below).

Two consequences worth knowing:

- The whole feature degrades to nothing. Both requests are `fetch`es that
  swallow their errors, so an offline editor draws no chips and offers no
  suggestions, and typing a mention by hand works exactly as it always did.
- The check reports **which** handles it looked at (`checked`), not only which
  resolve. It caps how many one request answers about (`Mentions.max_check_handles/0`),
  and a client that read silence as "no such account" would strip the chip off a
  real member the moment somebody pasted a long list.
- The picker answers nothing below two characters — the floor its sibling
  typeahead `Posts.search_users/3` already uses. One letter names half the site,
  so those rows would be noise and the scan behind them wasted.
- The client's copy of the grammar (`MENTION_RUN` in `assets/js/markdown_editor.js`)
  refuses a fediverse address: `@ada@mastodon.social` names somebody else's
  account, and chipping the `@ada` in front of it would claim a member of ours
  had been named. An address on our own host is a real mention and the renderer
  links it, but it goes unchipped too — the client does not know which host is
  ours, and a missing chip is the harmless direction. It refuses a Bluesky
  handle for the same reason, and nothing fails when the two copies drift: the
  server counts zero mentions in `@hilwiller.bsky.social` while the composer
  would chip `@hilwiller`, ask whether that member exists and spend one of the
  five mentions a post may carry.

Out of scope on purpose: completing a remote `@user@host` address. Only local
mentions become `Mention` tags in the outgoing Note (`VutuvWeb.Fediverse.Docs`),
and a remote address in the body is left to the reader's server — offering
remote accounts would promise a notification we do not send. Raw **source
mode** has no picker either: the caret there is in a plain `<textarea>`, where
placing a panel means measuring text in a mirror element, and the people who
switch to it are the people who type handles from memory anyway.

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

## The account card behind a remote handle

An account on another network has no profile here, so every place that named one
had to answer "who is this" by sending the reader somewhere — that server, or
the cached account page at `/system/fediverse/account/:id`, which they then had
to come back from. A plain left click by a signed-in member now opens a small
card over the handle instead: name, address, self-description, how much of them
we hold, one Follow button, both mutes, and the two ways onward.

The card's markup is a server-rendered fragment
(`VutuvWeb.RemoteActorCardController`, POST only — resolving an unknown address
is an outbound request, so it may not be reachable by a link or a crawler), and
`assets/js/mention_card.js` positions a box and swaps the HTML in. It binds to
`a[data-remote-actor]` and two places write that hook:

| Writer | Anchors |
|---|---|
| `VutuvWeb.Markdown` | a `@user@host` inside any rendered body — a post, a **chat message**, a work-experience description |
| `VutuvWeb.FediverseComponents.remote_actor_link/3` | every other remote account the app draws |

The second is the chokepoint. It owns **both** halves of the answer — where the
anchor leads and what a press does — and its ten callers are the post card's
header and its reaction chips, the boost banner, the "Replying to" line, a
notification row, the followers and following tables (a member's own and an
organization's), the feed's filter band, and a member's forwarding address after
they moved. A handle that is not a full `user@host` (the actor document carried
no username, so `Handle.display/2` fell back to `@name` or a bare `@host`) gets
no hook and keeps its plain link: the card is addressed by the address.

Nothing else about the anchor changes, so the `href` stays its whole truth — a
middle click, a copied link, a logged-out visitor and a page whose JavaScript
never arrived all still go to the destination. Those anchors are often
`<.link navigate>`, which is why the JS stops the click's bubble as well as its
default: LiveView's nav listener on `window` reads `data-phx-link` without
asking whether the default was prevented, so the card would open and the page
would leave underneath it in one gesture.

Three surfaces deliberately stay out. The quoted-post card is one big link to
the original, and an anchor inside an anchor is not markup. `/settings/fediverse/move`
shows the member their *own* forwarding address, where a Follow button is the
wrong offer. And the admin queues name a handle as a row label, not as somebody
to meet.

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
  `mentioned_users/2`, `resolvable_handles/1` behind every mention link, and
  `suggest/3` + `check_handles/1` behind the picker).
- `lib/vutuv_web/controllers/mention_controller.ex` — the picker's two JSON
  answers, `assets/js/mention_picker.js` the panel, `assets/js/markdown_editor.js`
  the trigger + the chip decoration.
- `lib/vutuv/posts.ex` — `sync_mentions/1`, the `post_mentions` reconcile.
- `lib/vutuv/posts/post_mention.ex` — the resolved index row.
- `lib/vutuv/activity.ex` — `mention_events/1` + the `"mention"` feed source.
- `lib/vutuv/accounts.ex` — `update_username/2` + notification creation.
- `lib/vutuv/accounts/handle_change_notification.ex` — the durable row.
- `lib/vutuv_web/live/notification_live/index.ex` — the `mention` and
  `handle_change` renderings.
- `lib/vutuv_web/components/fediverse_components.ex` — `remote_actor_link/3`,
  the one owner of where a remote handle leads and what a press does;
  `lib/vutuv_web/controllers/remote_actor_card_controller.ex` +
  `templates/remote_actor_card/card.html.heex` render the card,
  `assets/js/mention_card.js` positions it.
- `test/vutuv/mentions_test.exs`, `mentions_local_address_test.exs`,
  `vutuv_web/markdown_local_address_test.exs`, `vutuv_web/mention_form_test.exs`,
  `mention_existence_test.exs`, `mention_suggest_test.exs`,
  `vutuv_web/controllers/mention_controller_test.exs`,
  `vutuv_web/live/composer_mentions_test.exs`,
  `mention_limit_test.exs`,
  `mention_notifications_test.exs`, `handle_availability_test.exs`,
  `accounts/handle_change_propagation_test.exs`,
  `vutuv_web/live/handle_change_notification_test.exs`,
  `vutuv_web/components/remote_actor_link_test.exs`,
  `vutuv_web/controllers/remote_actor_card_test.exs`.
