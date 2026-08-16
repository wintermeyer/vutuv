# Post translations

Language, the fediverse way (milestone 13): the author **declares** each
post's language in the composer (default: their UI locale) — nobody guesses.
Translation is **on-demand** via a local Ollama text model: a reader asks, a
job queues, the result is cached per post + target language. Never
pre-computed, never backfilled, never federated. Public, logged-out,
agent-format and ActivityPub surfaces always show the original.

Everything lives in `Vutuv.Translations`; the config flag is
`:translate_posts` (shipped **off**, `TRANSLATE_POSTS=true` opts in;
`docs/ADMINS.md` has the operator view).

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
- NULL means legacy/undeclared: shown to everyone, never auto-translated,
  no `contentMap` outbound.

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

Every card whose language differs from the UI locale (or declares none)
carries a quiet **Translate** action on the LiveView surfaces (feed,
permalink thread, profile — issue #1462): tap → pending line → the worker's
broadcast swaps the translated body in, labelled "Translated from X" with
the original one tap away. A shown translation renders through the normal
Markdown pipeline (local posts) or as plain text (remote content), and the
card's `lang` attribute follows what is shown. The host-side half is
`VutuvWeb.Live.PostTranslations`; the card-side half is the `translations`
map + `translatable?` flag on `VutuvWeb.PostComponents`.

The **feed language preference** (issue #1461, on /settings/preferences)
adds Mastodon's chosen-languages filter: `users.feed_languages` (nil = all)
plus the `:feed_foreign_posts` pref — original (shipped default) /
translate / hide. Hide is `Posts.language_scope/2` (`is_nil or in` — NULL
never hides) applied inside every feed source query; translate mode
auto-requests translations for rendered foreign cards (one batched
`fresh_translations/2` query per page, `PostTranslations.auto_translate/3`).
Feed only; profiles, permalinks, search and public surfaces are untouched.

## What deliberately does not exist

- No backfill, no bulk pre-computation: a job exists only because a reader
  wanted that translation.
- No language auto-detection of local posts: the author declares.
- No federation of translations: only originals leave the house.
- No translation UI on public/logged-out/agent surfaces.
