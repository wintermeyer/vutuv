# Post translations

Language, the fediverse way (milestone 13): the author **declares** each
post's language in the composer (default: their UI locale) — nobody guesses.
Translation runs through a local Ollama text model and is cached per subject +
target language; never federated, and public, logged-out, agent-format and
ActivityPub surfaces always show the original.

Two things fill that cache. A **reader asks** — the original design, and still
the only thing that can translate remote content. And, for **our own posts
only**, a background sweep pre-translates into every locale the installation
serves, so the common case is a cache hit and nobody waits for a model at all.
The sweep never gets in the reader's way: its jobs rank behind theirs, a reader
asking for something it already queued joins that same job at the front, and it
stands down entirely while image moderation needs the shared box.

Everything lives in `Vutuv.Translations`; the config flags are
`:translate_posts` (shipped **off**, `TRANSLATE_POSTS=true` opts in) and
`:precompute_translations` (on, `PRECOMPUTE_TRANSLATIONS=false` opts back out
of the sweep alone); `docs/ADMINS.md` has the operator view.

## Language columns

`posts.language`, `fediverse_posts.language` and `fediverse_notes.language`
hold a **lowercase primary language subtag** ("de", "en") or NULL. All entry
points normalize through `Translations.normalize_language/1` ("de-AT" → "de",
garbage → nil), so the columns only ever compare short single codes.

- `posts.language` is written by the composer's language select
  (issue #1489). `Post.cast_language/1` maps an unknown or tampered select
  value to nil rather than a validation error (the license principle).
  The declared value rides post drafts across a reload too.
- The remote columns are filled at ingest from AS2 `contentMap`
  (issue #1488).
- NULL means undeclared: shown to everyone, never auto-translated, no
  `contentMap` outbound, and **no Translate action** (issue #1535 — see
  below).

## Filling the gaps (issue #1535)

Declaration covers what the composer writes and what a `contentMap` carries,
which left two piles undeclared: everything written before the column
existed, and every remote object whose origin sends no `contentMap` — most of
them. For those rows the reader's language filter never applied, and the
Translate action offered itself on posts in the reader's own language, where a
tap spent an Ollama slot translating German into German.

`Vutuv.Translations.Detector` closes that: **one cheap call** — a short
markup-stripped sample, one JSON field, the same model as the translator
(a second model would make Ollama swap tens of gigabytes between a detection
and a translation). Only a curated language (`Vutuv.Languages.known?/1`) is
stored, because that list is what a reader can tick on
/settings/preferences — a code outside it could be hidden by the filter and
never chosen back. A detected language then counts like a declared one,
filter included.

`posts.language_checked_at` (and its twins) is the sweep's own clock:
**stamped on every outcome**, including the one where the text could not be
placed at all, which keeps `language` NULL and takes the row out of the work
list — an unstamped skip would be due again on the next round and hold the
front of every batch forever (the `refresh_counts` starvation lesson,
`test/vutuv/translations/language_detection_test.exs` calibrates against it).
A service failure is the one outcome that stamps nothing and stops the batch:
the row is not the problem. Rows are handed out **newest first**, against the
oldest-first convention here and deliberately — the language of a post that is
in somebody's feed right now is the one a reader can use, and the inflow is
orders of magnitude smaller than one poll interval's capacity, so nothing
starves.

Two entry points, one loop (`Translations.detect_all/1`): the worker's poll
takes a couple of rows **behind** the reader-driven queue and never on
`nudge/0`, while the one-off backfill of the old pile is a deliberate run —
`mix vutuv.translations.detect_languages` locally,
`Vutuv.Release.detect_post_languages/1` on a release. The stamp is written
with `update_all`, never a changeset: a post whose `updated_at` moves more
than a minute past `inserted_at` renders as "edited", and a backfill must not
put that mark on hundreds of posts nobody touched.

Within a round the rows go to the model **in parallel**, bounded by
`Vutuv.Ollama.concurrency/0` — every `:ollama_url` entry but the patient
fallback at the end, unless `OLLAMA_CONCURRENCY` says otherwise — and the
batch is widened to at least that, so no instance sits out a round (issue
#1573). On a one-GPU installation that bound is 1 and nothing changes. One
row at a time was one
Ollama instance at a time, so a second GPU box named in `:ollama_url` never
took any of this work; it was reached only when the first box *failed*. Only
the model call runs in a task, the stamp is written back in the one process,
which keeps the writes serialised and needs no row claiming: a round selects
its rows once and hands each to exactly one task. Two sweepers running at
once (an operator's backfill beside the worker's poll, or the two releases
that overlap during a blue/green switch) still fetch the same batch and
duplicate the calls — wasted inference, never a wrong answer, since both write
the same language. A `SKIP LOCKED`-style claim is what a genuine second
*worker* would need, and there is no second worker.

## The subject triple

A translation's subject is exactly one of a local post, a cached remote post,
or a cached remote reply. The `translations` and `translation_jobs` tables
encode that as a nullable id triple (`post_id` / `remote_post_id` /
`note_id`), CHECK-enforced to exactly one — and the triple is **confined to
the context**: outside callers hand over the subject struct and read
`Translations.subject/1`. No ad-hoc joins on the triple (the organization
milestone's NULL-pair lesson).

## The cache

One `translations` row per subject + target language (partial unique
indexes). `source_sha256` binds the row to the exact source text (body +
content warning) it translated: an edited source makes the row stale,
`fresh_translation/2` answers nil, and the next request re-translates —
upserting the same row in place. Rows die with their subject
(`on_delete: :delete_all`).

## Requests and the queue

`Translations.request(subject, target)` is what a reader's translate tap
comes down to: `:disabled` (flag off), `{:cached, translation}` (fresh row),
or `{:queued, job}`. Open jobs are deduped per subject + target (partial
unique index over `pending`/`running`); resolved rows stay as the audit
trail, and a `failed` row never blocks a deliberate later request.

`translation_jobs` follows the `image_scans` row-is-the-job shape (status,
attempts, `next_attempt_at`), so the queue is durable across deploys and
power loss. `Vutuv.Translations.Worker` (the `ImageScanWorker` shape: slow
poll + `nudge/0` on request, `resume_stuck/0` on boot) drains it via
`deliver_due/1` in small batches — the Ollama box is shared with the
fail-closed image moderation, which keeps priority.

## Who goes first (the priority column)

`translation_jobs.priority` runs the drain **lower first**: 0 is somebody
waiting, 50 is the background sweep. Three mechanisms make that real, and
`test/vutuv/translations/priority_test.exs` calibrates each against the shape
without it:

1. **Order.** `list_due/1` sorts by priority, then age, then id — the id
   because `inserted_at` holds whole seconds and same-second ties are ordinary.
2. **Promotion.** A reader asking for a translation the sweep already queued
   lands on *that* row and moves it to the front (`promote/2`), rather than
   opening a second job to translate the same text twice. The comparison makes
   it safe both ways: the sweep meeting a reader's job leaves it alone, and a
   `running` job is never touched — it is already as fast as it gets, and
   moving its `updated_at` would lie to `resume_stuck/0`.
3. **One job per query.** A translation runs for minutes, so `deliver_due/1`
   re-asks between jobs instead of selecting a whole batch up front. Otherwise
   a reader tapping Translate mid-drain waits out every remaining row of a
   batch chosen before they asked.

The column's DEFAULT is the reader value, which is what makes the migration
N-1 safe: the release still serving traffic during a blue/green switch inserts
jobs without this column, and every one of those is a reader's request.

## Pre-translating our own posts

`Translations.enqueue_background/1`, run from the worker's poll. Local posts
only — our own content, in a language somebody declared or the detector
placed, not frozen, with a body to translate — into every configured locale
but its own.

Three bounds, and each answers a specific way this could go wrong:

- **The backlog cap** (`@backlog_cap`, 20) is the threshold. While that many
  of the sweep's jobs are outstanding a round does nothing at all, so the
  sweep tops a short pile back up rather than handing the pipeline a table's
  worth of work, and an Ollama that falls behind simply stops being given
  more. A reader's jobs are not counted — they are never what the cap is
  protecting the box from.
- **`posts.translations_enqueued_at`** is the sweep's own clock, stamped on
  **every** outcome including "everything was already translated, nothing
  opened". An unstamped no-op is due again on the very next round and holds
  the front of the work list forever — the `refresh_counts` starvation lesson,
  and `test/vutuv/translations/precompute_test.exs` is calibrated against
  exactly that shape. Written with `update_all` and that column alone: a post
  whose `updated_at` moves reads as "edited", and a sweep must not put that
  mark on hundreds of posts nobody touched.
- **Reconsideration** is an edit (the work list compares the stamp against
  `updated_at`, so an edited post is a candidate again at once) or the
  `@reconsider_after_seconds` interval. That interval exists for the case no
  edit will ever re-open: a translation that failed while Ollama was down.

The worker yields the box to image moderation (`ImageScans.busy?/0`): while any
picture waits for its verdict the poll neither opens background jobs nor drains
the ones it has (`Worker.drain_priority/0`). Both queues share one Ollama and
use *different* models, so alternating between them swaps tens of gigabytes,
and a member staring at a placecard where their photo should be costs more than
a translation arriving a poll later. Reader requests drain throughout.

One dependency runs the other way and is easy to miss: **a post nobody could
place a language for is never a candidate**, so the sweep is only ever as
complete as the detection above it. That is why the detection gate asks
`Translations.reader_waiting?/0` rather than whether the queue is empty — with
a standing background backlog, "is the queue empty" is answered no forever, and
detection would switch itself off for good.

Nothing here is federated or shown on a public surface; the sweep only fills
the same cache a reader's tap fills.

**Every outcome stamps the job, including the do-nothing branches** (subject
gone, translation already stored). An unstamped skip would be due again on
the next drain and hold the front of the oldest-first batch forever — the
`refresh_counts` starvation lesson; `test/vutuv/translations/queue_test.exs`
holds the line.

## The translator

`Vutuv.Translations.Translator` makes **one** Ollama call per (subject,
target): the model translates and reports the source language as a byproduct
(JSON via structured outputs) — there is no separate detection step anywhere.
Local posts translate as Markdown (code fences, URLs, `@handles`, `#tags`
untouched; the result renders through the normal `VutuvWeb.Markdown`
pipeline + sanitizer, so no new XSS surface); remote content translates as
plain text, content warning included. `num_ctx` is set explicitly (16k —
Ollama truncates silently otherwise).

Two error classes: `{:service, _}` (Ollama down — the job retries patiently;
a stall on the shared box is not a failure) and `{:content, _}` (the answer
failed the plausibility gate: empty, absurd length ratio, altered code
fence — junk is never stored). Both strike toward a cap, at which the job
ends `failed` and the card keeps showing the original: **fail-open**, the
exact opposite of image moderation, because a missing translation costs a
tap while a missing image would leak.

A garbage source-language report is stored as `und` (undetermined) — a valid
ISO 639 tag that the display layer knows to show no source label for, and
that never goes on the wire (#1488 emits no `contentMap` for it).

The model is `:ollama_translation_model` (`OLLAMA_TRANSLATION_MODEL`,
default `gemma4:31b` — issue #1455's eval: the smaller/faster models invert
negations). On success the worker broadcasts `{:translation_ready, row}` on
`Translations.topic(subject)` for the live swap-in (issue #1462).

## The reader's controls

Every card whose language is **known** and differs from the UI locale carries
a quiet **Translate** action on the LiveView surfaces (feed, permalink thread,
profile — issue #1462): tap → pending line → the worker's
broadcast swaps the translated body in, labelled "Translated from X" with
the original one tap away. A shown translation renders through the normal
Markdown pipeline (local posts) or as plain text (remote content), and the
card's `lang` attribute follows what is shown. The host-side half is
`VutuvWeb.Live.PostTranslations`; the card-side half is the single
`translations` attr on `VutuvWeb.PostComponents` — a map means the viewer
gets the controls, nil (every non-LiveView surface) means they do not.

The **feed language preference** (issue #1461, on /settings/preferences)
adds Mastodon's chosen-languages filter: `users.feed_languages` (nil = all)
plus the `:feed_foreign_posts` pref — original (shipped default) /
translate / hide. Hide is `Posts.language_scope/2` (`is_nil or in` — NULL
never hides) applied inside every feed source query; translate mode
auto-requests translations for rendered foreign cards (one batched
`fresh_translations/2` query per page, `PostTranslations.auto_translate/3`).
Feed only; profiles, permalinks, search and public surfaces are untouched.

## What deliberately does not exist

- No pre-computation of **remote** content: the sweep translates our own posts
  only. A cached remote post or reply is translated because a reader asked.
  (Scope, not principle — it is 2,194 rows against 525, on a box that is also
  moderating photos.)
- No "translate everything now" run. The sweep is paced by the backlog cap on
  purpose; a one-off bulk pass is the thing the cap exists to prevent.
- No language guessing where the author declared one: a declaration is never
  second-guessed, and the composer preselects the author's UI locale.
- No federation of translations: only originals leave the house.
- No translation UI on public/logged-out/agent surfaces.
