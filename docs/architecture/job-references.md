# Employment references (Arbeitszeugnisse)

A member uploads the employment reference an employer gave them, attaches it to
their CV, optionally publishes it, and can have it reviewed by a language model
running on this installation's own infrastructure.

Modules live under `Vutuv.References`; storage is `Vutuv.JobReferenceDocument`;
the web side is `VutuvWeb.JobReferenceController`,
`VutuvWeb.JobReferenceDocumentController` and `VutuvWeb.ReferenceCheckLive`.

## Private by default

`job_references.public?` starts false and only leaves that state through an
explicit tick in the same submit (`JobReference.changeset/2` → `cast_visibility/2`,
stamping `public_consented_at`). This is the one column on the schema whose
wrong default is a privacy incident rather than a bug: a Zeugnis carries a
former employer's graded judgement of a person, written in a code where
"zufrieden" without "voll" is a bad mark.

Two gates decide whether anyone but the owner sees a reference
(`JobReference.publicly_visible?/1`): the member published it, **and** any
attached document cleared AI image moderation. The public queries in
`Vutuv.References` carry both as SQL rather than filtering afterwards, so a
paginated read can never return a short page.

Going private again clears the consent stamp: it consented to *being public*,
and a stale timestamp on a private row would misread as agreement.

## Whose Zeugnis it is

A Zeugnis is a named person's employment history plus a former employer's
graded judgement of them, and here a language model reads it as well. Filing
somebody else's is therefore not a house-rules question but the processing of
another human's personal data with nothing behind it.

Creating an entry asks for one tick — "this reference was issued to me" — and
refuses the save without it (`JobReference.cast_ownership/2`, a changeset
error, so the JSON API hits the same wall the form does). It stamps
`owner_confirmed_at`, and **the stamp is the point**: a sentence on the form is
unenforceable and leaves nothing behind, while a timestamp lets the operator
say what was affirmed and when, a year later, when somebody writes in saying
that Zeugnis is theirs. Same arrangement as `public_consented_at` one field
over — the choice and the evidence that it was made — and neither column is
mass-assignable, so no client can affirm on a member's behalf.

Asked **once, at creation**, keyed on Ecto's own insert-or-update signal
(`__meta__.state`) rather than on a nil id. Not on every edit: the tick would
then sit unanswered under a title change that needs nobody's permission, and a
gate a member steps over weekly is a gate they stop reading. It is placed
*above* the upload zone, because it is a question about whether to upload at
all, and a ticked box survives an unrelated validation failure
(`JobReferenceHTML.consent_ticked?/2` reads the changeset's raw params) — a
promise re-made on every attempt stops being read.

Deliberately **not a modal**. A modal asks the same question with more
interruption and no more weight; what makes this one worth anything is that the
save does not happen without an answer and the answer is kept.

## From file to text

The review reads the **text**, never the file. `Vutuv.References.TextExtraction`
ladders down three rungs, each capability-detected:

1. `pdftotext -layout` for a PDF carrying real text (the common case).
2. Tesseract with German language data, for a scan.
3. A vision model, as the last resort.

Tesseract goes first although it scores worse overall. Measured on a noisy
scan, `qwen3-vl:8b` reached 99.4 % word recall and transcribed every
grade-carrying formula exactly — "vollsten" against "vollen" against a bare
"Zufriedenheit" — but turned "Kundenstammdaten" into "Kundendaten". A language
model does not misread, it **normalises plausibly**, so its errors arrive
looking like correct German; Tesseract's look like errors. In a document where
one word carries the grade, the visible error is the safer one.

`image_only?/2` picks the rung: fewer than 50 printable characters per page
means the PDF is a scan. Whatever comes out is offered to the member for
proof-reading, labelled with the rung that produced it (`body_source`), and
their own text always wins over anything a machine read.

## The prompt is data, not source

The analysis runs on an open skill maintained at

    https://github.com/Klotzkette/arbeitszeugnispruefer-skill

**A copy ships in this repository** at `priv/reference_skill/SKILL.md`, and that
copy is what runs. The prompt that was reviewed is the prompt that produces
readings, a change to it is a reviewable commit, and no installation depends on
GitHub being up to answer a member. `SkillRefresher` can re-fetch it daily, but
that is **off by default** (`FETCH_REFERENCE_SKILL`): for a text that generates
legal analysis, an unreviewed overnight change upstream is worse than waiting
for a deploy. Rows accumulate in `reference_skill_versions`,
and every check records the `skill_version` + `skill_sha256` that produced it,
so two results months apart can be explained rather than merely compared.

Adoption is **fail closed** (`Skill.valid_body?/1`): a fetched body must declare
the skill's frontmatter name, carry a `Version:` line and be at least 50 KB.
Anything else leaves the previous prompt in force. Failing open would be worse
than it looks — a short prompt does not make the model refuse, it makes it
answer from training alone, still formatted and still confident, with no legal
anchors at all.

## The context window is a correctness problem

The prompt measures ~35,200 tokens. Ollama's common default context is 32,768,
which is smaller, and it does not refuse — it truncates and answers anyway:

    num_ctx=32768  ->  prompt_eval_count = 16,386 of 35,559
                       no § 109 GewO, no Beweislast, still a polished report
    num_ctx=65536  ->  prompt_eval_count = 35,559

So `Vutuv.References.Analyst` sends `num_ctx` explicitly on every request,
refuses to start when the configured window cannot hold what it is about to
send, and compares `prompt_eval_count` in the reply against a conservative
lower bound derived from what it sent. Both are the same rule: an answer whose
completeness cannot be proven is not an answer.

The skill is the system message and the Zeugnis a user message, so the ~35,200
token prefix is byte-identical across checks and the server reuses its KV
cache — measured, that drops the prefill from 75 s to 5 s from the second check
on. Nothing that varies may join the system message.

The Zeugnis is untrusted input: it travels fenced and labelled, with the
standing instruction that anything inside is content to be analysed and never
an instruction to follow. The model's answer is untrusted output for the same
reason and renders through `VutuvWeb.Markdown.render/1` (escape, Earmark,
sanitise), never the trusted `DevDocMarkdown`.

## The queue

`reference_checks` is the `image_scans` shape: the row **is** the job, and once
finished it is the stored result. A check occupies the model for minutes
(measured ~45 s on a warm GPU, ~11 minutes on 32 CPU cores) and a typical
Ollama answers one request at a time, so this is a real queue with a real wait
and the member is told where they stand (`Checks.queue_position/1`) rather than
shown a meaningless spinner.

Queue position counts by **id**, not `inserted_at`: `timestamps()` has second
resolution, so three checks queued in the same second would each report "you
are next". Ids are UUID v7, whose leading bits are the creation timestamp.

Errors are two-class. `{:service, _}` (model unreachable) is not this Zeugnis's
fault: retried on a backoff ladder without spending an attempt.
`{:analysis, _}` (truncated prompt, misconfigured window, empty answer) is
counted, and at three attempts the check fails visibly rather than looping
forever on an unchanged misconfiguration. Stored error labels never carry
Zeugnis text — they reach log lines and admin screens.

Every state change broadcasts on the member's own `Vutuv.Activity` topic, so
`ReferenceCheckLive` follows the row without polling. Queue *movement* has its
own topic (`Checks.subscribe_queue/0`): "two ahead of you" goes stale when
somebody else's check finishes, and that never touches the waiting member's own
topic.

### Surviving a reboot and a deploy

A check holds the model for minutes and dies with the release holding it: a
blue/green deploy stops the old slot mid-inference, and so does a reboot. The
row stays `running` with nobody running it.

A running check therefore stamps `heartbeat_at` about once a minute
(`Checks.with_heartbeat/2`, an unlinked beater that also stops when the process
that started it goes away), and `Checks.resume_stuck/0` re-queues anything
silent for five minutes — on worker boot and on every poll. The stamp is what
separates **slow** from **gone**: recovery used to key on `updated_at` with a
one-hour cutoff, which was the only safe guess while the row carried no
liveness signal, since an inference legitimately runs for fifteen minutes. A
row with no stamp at all (claimed by a release predating the column) reads as
stranded, which is correct.

The match is on `status` **and** the stale stamp, so a check another node is
actively beating is never taken from it.

### How long it takes

`duration_ms` is stamped around the request by `Analyst`.
`Checks.typical_duration_ms/0` answers the **median** of the last 20 finished
runs — the median, because the same document takes ~45 s on a warm GPU and ~11
minutes on a cold CPU instance, and one such outlier would double the number
every member is quoted.

`Checks.estimated_wait_ms/1` turns that into what one member still has to wait
for, and it counts the **whole pipeline**: the remaining part of the run
currently occupying the model (which sits in nobody's queue position), every
check queued ahead, and their own run, plus a 20% margin. Counting only the
queued ones quotes a member one whole run too little exactly when the model is
busy, which is when somebody is looking. The margin rides on the member-facing
quote only; `typical_duration_ms/0` stays the plain measurement, because a
statistic that quietly pads itself is no longer one.

The quote is shown **only once a check exists** — waiting or running. Beside
the button there is none, and that is deliberate: a duration offered before the
member has committed to anything is a promise with nothing behind it, and a
median that one long document or a cold model beats is exactly the kind of
number that gets quoted back at us. Where the wait *is* shown, the queue
position it is built on is shown with it, which is what makes it checkable.

### The allowance

`REFERENCE_CHECKS_PER_DAY` reviews per member per **rolling** 24 hours
(`Checks.window_seconds/0`, a constant), so somebody who used their last slot at
23:00 is free again at 23:00 the next day and not at midnight.
`JobReferenceHTML.rate_limit_message/1` says so in two wordings, and **both name
a number and a time**: the exact one from `Checks.next_slot_at/1` ("your 10
reviews for the last 24 hours; the next is possible again in about 3 hours"),
and a fallback quoting the whole window for a member with nothing in it to count
from. The fallback used to read "you have used your reviews for now, please try
again later", which says neither how many nor when — and every rate-limited
member saw exactly that, because `ReferenceCheckLive` rendered its error line
through a function component whose `attr` list had no `viewer`, so the id the
exact wording needs arrived as nil and the vague branch always won. A function
component receives exactly the assigns it is passed; `assigns[:viewer]` inside
one is not a window onto the socket.

### Binding a result to a text

`body_fingerprint` binds a result to the text that produced it. Editing the
Zeugnis marks the result **outdated**, not deleted: the earlier reading is
still worth having, it simply no longer describes what is on screen. The
outdated state offers the way out (another review) rather than only stating the
problem.

The fingerprint is taken over the **canonical** text
(`JobReference.normalize_body/1`, line endings to LF), because the question is
"is this the same text", not "are these the same bytes". An HTML `<textarea>`
submits its line breaks as CRLF whatever it was handed, so every save of an
entry — a corrected title, the visibility tick, a CV link — rewrote a body the
member never touched and reported every earlier review as describing a version
that never existed. Both stored dev results showed it, and both fingerprints
matched their body exactly once the carriage returns came off.

`grade_span` stores the overall grade the run arrived at, parsed once by
`Check.parse_grade_span/1` at the moment the answer lands. Saving the work on
every render is the small reason; the real one is that the value is then
settled by the run that produced it, so sharpening the parser later cannot
restate a grade a member was already shown beside a Zeugnis they have since
sent to an employer. `Check.grade_span/1` falls back to parsing for rows
written before the column.

### Telling the member it is done

**One mechanism, not a special case.** Every notification email in
`Vutuv.Activity` goes through the same gate (`notification_email/3`): the
notification is shown in the app, and the email is what carries it to somebody
who is not there to see it. A member still using vutuv gets the badge and
nothing in their inbox, whether the news is a follow, an endorsement or a
finished review. It used to be unconditional, which meant a member reading
their notifications was mailed about the row they were looking at.

"Not here" is `Sessions.active_since?/2` over five minutes, off `last_seen_at`
— deliberately **not** `VutuvWeb.Presence`, which is gated on the "show when
I'm online" setting: that is a privacy choice about a green dot next to your
face, and it must not double as "you may email me".

**The gap, stated rather than papered over:** absence is measured *once*, when
the notification is made. The fuller model — mail only after somebody has been
away *for a while*, and only if they configured it — needs someone to come back
later and look. That shape already exists for direct messages
(`Vutuv.Chat.UnreadNotifier`: a `notified_at` debounce, a sweeper, a per-member
delay in `dm_email_delay_minutes`) and the feed has the read marker it would
need (`users.notifications_read_at`). Until a sweeper covers this feed too, a
member who closes the tab a minute after a notification appears hears nothing
by mail; the notification itself is waiting for them.

A review takes minutes, and behind a queue it takes somebody else's minutes
too, so the waiting panel explicitly invites the member to leave the page. That
invitation is only honest because the result then finds them: `Checks.finish/3`
calls `Activity.notify_reference_check/2`, which pushes the in-app notification
(also derived from the finished rows, so an open page and the bell badge agree)
and mails the member.

The notification is the one kind in `Activity.kind_specs/3` with **no actor**:
nobody did this to the member, they asked for it. Both the notification and the
mail name the Zeugnis and the grade — the fact they waited for, and burying it
one click deeper would be a tease — but the report itself never travels by
mail, being a long legal reading of a private document.

`email_on_reference_check?` is the only notification-email preference that
defaults to **true**. The others announce what somebody else did; this one
answers a question the member asked, and switching it off by default would take
back the "you can close this page" the UI just promised.

### What the account log keeps

Adding, changing, deleting and reviewing a Zeugnis each write a
`Vutuv.AccountEvents` row (`job_reference_added` / `_updated` / `_removed` /
`_reviewed`), so `/settings/activity` answers "who touched my references, and
when". The rows carry **no title, no employer and no grade**: this log outlives
the entry by up to a year and support reads it too, so a member who deletes a
Zeugnis must not leave "Zeugnis Muster GmbH, Note 4 bis 5" behind. `_updated`
carries the submitted field *names*, `_reviewed` the model that read it — which
is worth keeping, since the model this installation runs will have changed by
the time anybody asks.

## One country's law

The prompt reads **German** employment law (§ 109 GewO, § 630 BGB, § 16 BBiG
and BAG case law). Austria (§ 39 AngG) forbids the coded grading it decodes and
Switzerland (Art. 330a OR) has its own practice, so running it on a foreign
document would produce a confident answer about the wrong legal system.

Each entry therefore carries a `country` (ISO 3166-1 alpha-2, NOT NULL,
prefilled from `Vutuv.Geo.default_country/0`), and the review is offered only
for countries in `:reference_check_countries` (default `["DE"]`). Uploading,
attaching and publishing work everywhere. Where the review does not apply, the
UI **says so** in place of the button: a missing control reads as a broken
feature.

## Deletion

Three paths clear a stored document, all sharing
`JobReference.document_reset_fields/0` so none can forget a column: the member
deletes the entry, moderation rejects the document (the entry and text survive;
the model judged a picture, not the words), and `Accounts.delete_user/1`. Links
and checks cascade in the database; files do not, so each path calls
`JobReferenceDocument.delete/1`.

**A member cannot detach the file on its own**, and there is deliberately no
route for it. The review grades the text, but the text is only worth something
because a document was read to produce it, so an entry holding one without the
other would be a claim with nothing behind it. Uploading a new file replaces
the old one; getting rid of the file means deleting the entry, which the
confirmation says in as many words ("this reference, its document and its
review").

## Telling the member what happens to their document

`/settings/job_references` closes with a plain-language box ("How the review
works"): the document is analysed on this installation's own machines and goes
to no cloud service, the model is open source and named, the yardstick is the
published Arbeitszeugnis-Prüfer with its URL, the result is private even when
the Zeugnis is published, and it is not legal advice.

**Every fact in it is read from configuration** — the model tag
(`Analyst.model/0`), the machine (`Analyst.hardware/0`), the country
(`Analyst.country/0`, an ISO code so `Vutuv.Countries` names it in the reader's
own language) and the skill's own URL. That is not ceremony: this is the one
box whose whole value is that it is true, and a template spelling out one
operator's graphics card would be a lie on the next operator's server.

The country rides the **headline** (`JobReferenceHTML.check_location_heading/0`:
"Your reference stays on our servers in Germany."), the hardware the sentence
under it (`check_location_line/0`). The headline used to read "Your reference
stays here.", which answers a question about a *place* with the website the
reader is already looking at. Either fact may be unset, so both functions carry
a fallback that is still true with nothing configured.

It sits **below** the list, and it is a plain card rather than a disclosure:
transparency that has to be unfolded first is a claim rather than a practice.

## Configuration

See the environment-variable table in `docs/ADMINS.md`:
`REFERENCE_CHECKS_ENABLED`, `REFERENCE_CHECK_MODEL`, `REFERENCE_CHECK_NUM_CTX`,
`REFERENCE_CHECK_TIMEOUT`, `REFERENCE_CHECKS_PER_DAY`,
`REFERENCE_CHECK_HARDWARE`, `REFERENCE_CHECK_COUNTRY`, `FETCH_REFERENCE_SKILL`,
`REFERENCE_OCR`. The instance itself is `OLLAMA_URL`, shared with AI image
moderation and usable as a comma-separated priority list (`Vutuv.Ollama`).

## Why the review stops at the analysis

The skill can produce a ready-to-send Berichtigungsverlangen, a Klagestrategie
and a Vollstreckungsmodul for the individual case. vutuv asks it not to, and the
cut is made in the **instruction** rather than by hiding sections afterwards: an
unwanted letter that is never generated cannot be stored, cannot reappear
through a later formatting change, and costs the member no inference time.
`analyst_test.exs` pins the forbidden list so a tidy-up cannot quietly reopen it.

The line the copy follows comes from the smartlaw case, checked against sources
rather than recalled: **BGH, Urteil v. 09.09.2021, I ZR 113/20** (brought by RAK
Hamburg, confirming **OLG Köln, 19.06.2020, 6 U 263/19**) held that a document
generator is **not** a Rechtsdienstleistung under § 2 RDG — the provider does not
work a concrete individual matter, the software runs a fixed routine over
pre-modelled typical constellations like a form manual, and users expect no
individual legal analysis.

What *was* held unlawful there was the **advertising**: "Rechtsdokumente in
Anwaltsqualität" and "günstiger und schneller als der Anwalt" were misleading
under UWG, because they compare a software product with a legal service. That
part never reached the BGH — the wording was changed and the appeal withdrawn.

Hence the note under every result, in this order: *this is not legal advice*,
*we do not assess your case, this is an automated reading of the wording*, *for
a binding assessment ask a lawyer (Fachanwalt für Arbeitsrecht)*, and only then
the source. Nothing in vutuv's copy compares the review to a lawyer, and nothing
should be added that does.

**This is background for the design, not a legal opinion.** Get it reviewed by a
lawyer before launch.
