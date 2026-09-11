# Files on posts and messages

A post can carry files as well as photos and a clip: PDF, plain text and
Markdown to begin with (milestone #2102), and a message between two connected
members carries the same plus the photo formats (#2110). This document covers
how a file gets in, how its preview pages are rendered, what a message does
with one, and grows as the rest of the milestone lands: what a post shows and
hands out (#2108).

## One chokepoint

`Vutuv.Attachments.create_pending/3` is the only way a file enters an
installation. It is modelled on `Vutuv.Videos.create_pending_video/3`: the
composer uploads eagerly, the row exists with **no parent** while the author
is still writing, and a row nobody ever claimed is swept after a day
(`sweep_pending/1`, run by `Vutuv.Posts.PendingImageSweeper` beside the
pending photos and clips).

Its refusals come cheapest-first and nothing is written to disk until every
one has passed; the module's own doc lists them in order. Each is an atom the
composer turns into a sentence (`attachment_error_message/1`), because "that
file could not be processed" tells a member with a password-protected PDF
nothing they can act on.

## The format comes from the bytes

`Vutuv.Attachments.Format` decides what a file is, and the extension only
decides which names the installation offers at all and whether a text file is
labelled Markdown or plain. The two have to **agree**, so a ZIP called
`invoice.pdf` and a PDF called `notes.txt` are both refused: a lying name can
never route a file past its own gate. The module's own doc has the rest.

## The PDF gate

`Vutuv.Uploads.PdfGate` blocks four effects — the file cannot be read
(encrypted), it runs code when opened, it does something to the reader when
opened, it carries another file inside it — and **fails closed**: poppler
missing, poppler failing, or a scan that could not be finished is a refusal.
Three of the four are poppler's answers (`pdfinfo` for encryption and
JavaScript, `pdfdetach -list` for embedded files); `/OpenAction` no poppler
tool reports, so it is read from the bytes.

The one thing worth repeating outside that module: **a raw-byte scan alone is
not enough, and this was measured.** One `qpdf --object-streams=generate` run
moves every dictionary into a Flate-compressed object stream, after which
`grep -ac` finds zero occurrences of `/JavaScript`, `/OpenAction` and
`/EmbeddedFile` in a file that still does all three. So the scan also inflates
every stream it can, bounded against a decompression bomb. `attachments_test.exs`
tries every hostile PDF twice, as written and hidden that way; calibrated by
removing the inflation pass, the `/OpenAction` file is then **accepted** while
poppler still catches the other two.

It lives under `Vutuv.Uploads` rather than beside the context that added it
because two other doors already take a member's PDF and hand it back verbatim
(`Vutuv.QualificationDocument`, `Vutuv.JobReferenceDocument`), whose only check
is that page 1 renders. Neither calls it yet.

## Two copies on disk

`Vutuv.AttachmentStore` keeps the upload verbatim in the private
`originals/attachments/<token>/` tree and a served copy under
`attachments/<token>/`, both keyed by the row's URL token, never its id.
The served copy is a **derivation** of the original: it is what
`Vutuv.Attachments.Metadata` rewrites when a PDF has its metadata taken out
(#2107), while the private tree keeps its promise through all of it — that is
exactly what the member sent, byte for byte. Neither tree gets a `Plug.Static`
mount: every served
byte will go through an authorizing proxy (#2108). Both are gitignored, and
`test/vutuv/uploads_gitignore_test.exs` fails the build if that slips.

A file's preview pages (#2105) live under the same two roots —
`attachments/<token>/pages/<n>/` — so they need **no new upload tree** and
nothing new in `.gitignore` or that test.

## The budget

Two rolling windows per member, 24 hours and 30 days, counted from
`Vutuv.Attachments.Upload` — one ledger row per **accepted** upload, holding a
member, a byte count and a moment, and nothing about the file.

Two decisions sit in that sentence. **Accepted, not stored**: deleting a file,
or letting the sweep take it, gives no megabytes back, so an
upload-and-delete loop cannot run the disk down. **Rolling, not calendar**:
there is no midnight at which twice the day's allowance fits.

Admins have no budget. The composer shows what is left before the next file
flows, as a formatted byte figure and a percentage.

## Configuration

Everything is per installation, read in `config/runtime.exs` with the
`config/config.exs` values as defaults, and documented in the env-var table in
[ADMINS.md](../ADMINS.md): `ATTACHMENT_UPLOADS`, `ATTACHMENT_UPLOADERS`,
`ATTACHMENT_MAX_MB`, `ATTACHMENTS_PER_POST`, `ATTACHMENT_DAILY_MB`,
`ATTACHMENT_MONTHLY_MB`, `ATTACHMENT_PREVIEW_PAGES`,
`ATTACHMENT_RENDER_CONCURRENCY`, `PDFINFO_PATH`, `PDFDETACH_PATH`,
`PDFTOPPM_PATH`, `QPDF_PATH`.

`ATTACHMENT_UPLOADERS` is `admins` while the milestone is being built, the way
video was introduced: a post cannot show or hand out its files until #2108
lands, so nobody else is offered a picker yet — in the composer **or** in a
message, which reads the same switch. `ATTACHMENTS_PER_POST` and both budgets
cover a message's files too: "the same limits as a post" is what #2110 asked
for, so there is one set of numbers rather than two that can disagree.

## The nullable pair

`attachments.post_id` and `attachments.message_id` are the shape CLAUDE.md
warns about: at most one is set, and both are `nil` while the composer holds
the file. `Vutuv.Attachments.pending?/1` is the one place that asks, so a
later reader cannot write its own `is_nil/1` pair and get one of them wrong —
an inner join to `posts` would silently drop every message's file, and a
`NOT IN` over these ids without an `is_nil/1` branch is false for every row.

`pending_post_id` beside them is **not** a third parent but a reservation
(#2106): while a post is waiting for this file it names the file here, which is
what keeps the daily sweep and a re-mounted composer off it. Setting `post_id`
clears it in the same statement, so exactly one column ever answers "who holds
this file".

## Machines, and the metadata in a file (#2107)

### One standing decision, stamped onto each post

**"Search engines and AI may read my posts"** is a `Vutuv.Prefs` key,
`posts_machines_allowed?`, on `/settings/privacy`. It is asked **once**, not per
post: a composer that asked would put the same question in front of a member
several times a day, and the answer almost never changes between two posts.

The member's answer is copied onto the row **as the post is published**
(`Vutuv.Posts` private `seed_post/1`, the seed struct both member-post paths
build from) into `posts.noindex_noai?`, read back through
`Vutuv.Posts.machines_allowed?/1` and its query twin
`scope_machines_allowed/1`. Nothing re-reads the setting when a post is
rendered, and that is the design rather than an optimisation: a live read would
mean flipping the switch silently rewrote every older post, and for the ones
already federated it would promise a withdrawal nothing can perform. So each
post keeps what it went out with, an edit keeps it too, and the setting is only
ever the default for the next one. An explicit `noindex_noai` attr still wins,
which is what `POST /api/2.0/posts` sends.

A **page's** post does not take it: an organization has its own `seo?`/`geo?`,
and one publisher's private posture must not mute the brand they publish for.

A pref rather than a plain column because `nil` has to mean "never asked":
`noai?`'s column default is `true`, so 5,867 of 6,026 members on the dev copy of
production "carry" an answer nobody gave, and nothing can tell that from a real
one. Here NULL inherits the installation default, which an operator moves at
`/admin/preferences` — worth having, since an intranet installation may well
want the opposite posture.

### What "no machines" costs, and why the settings page says it

Saying no means `noindex, noai, noimageai` on the permalink and on every
`.md`/`.txt`/`.json`/`.xml` sibling, no sitemap entry, no place in the two RSS
feeds or on a tag page (both carry one all-yes `Content-Signal` for a whole
list), and no first line quoted on any shared listing surface. And it means the
post **is not federated at all** — not the Create, not a later Update, not the
unfreeze's republish, not a topic actor's Announce, not somebody else's boost,
not the `featured` collection, not the outbox count, and not the Note served on
request to an ActivityPub `Accept` header. A header is advisory and re-read on
every visit; a copy on somebody else's server is neither, so this has to be a
gate and not a directive. That sentence is the registry `hint` on
`posts_machines_allowed?`, so the member and the admin read the same words.

### The chokepoint

**A post's body leaves the database toward a surface a machine can read only
through a query that has been piped through `Vutuv.Posts.scope_machines_for/2`**
(or its anonymous case `scope_machines_allowed/1`). That is the invariant, and
it is enforced rather than remembered: `test/vutuv/post_body_chokepoint_test.exs`
reads the source, collects every function under `lib/vutuv/` that selects a post
`body`, and fails the build for any that does not pipe through the gate.

It is a property and not a list because three review rounds each produced a
complete measurement and each missed the next surface — the archive, the tag
pages and the calendar; then the conversation, the reply, the repost and the
profile document; then the profile HTML. The last pair is why the gate is in the
**query**: `recent_posts_by_authors/3` selects `body:` into bare maps, which no
struct-taking helper can reach, and `pinned_post/2` fetches by id rather than
through a timeline, so no listing gate applied. Both put a withheld post's whole
text on `/:slug`, which is public, anonymous, in the sitemap and carries no
`X-Robots-Tag`.

`scope_visible/2` is its mandatory partner and answers a different question — may
this **viewer** see it — so neither substitutes for the other. An exception is
explicit and carries its reason in the test's own `@deliberate` and
`@exempt_queries` maps; the silent absence of a check is what the guard exists to
stop.

### Where a withheld post is redacted, and where it is not

The switch protects the post's own documents; what it did not protect at first
was the post as it appears **inside somebody else's**, because a document's
robots axes are computed from its *subject* post and a conversation quotes other
people's. So `PostDoc` redacts **per entry**: `thread_entries/1` and
`reply_entry/1` hand back the sentence "Post not open to search engines" in
place of a withheld body, `withheld_excerpt/1` does the same for a quoted line
(`ProfileDoc` shares it for the pinned post), the reposts leg of
`author_timeline_query/3` drops a withheld post outright, and the archive's
one-level ancestor fallback stops printing a withheld parent above a reply card.

The **HTML conversation on a permalink still shows every word**. Page and doc
differ there on purpose: the promise is about machines, not about readers. The
archive listing is the one place they must agree, because that page is a crawl
surface — which is also why its withheld rows leave it.

### The metadata in a file

**"Remove the metadata from the files"** is `posts.strip_metadata?`, the
author's *answer*, and the one question the composer still asks — it is about
*these* files, so it belongs beside them, and it only shows on a new post
carrying one. What actually happened to a given file is
`attachments.metadata_stripped_at`. `Vutuv.Attachments.Metadata` is the one
place vutuv talks to `qpdf`, probed once per VM the way ffmpeg is, and the
switch is hidden where the binary is absent **or too old** — the probe asks
qpdf whether it knows the flags (`--help=--remove-info`), not whether the file
exists, because Debian 12 ships 11.3.0 and Ubuntu 24.04 ships 11.9.0 while
`--remove-info` arrived in 11.10.0. The run happens at **intake**, on every PDF,
deriving the served copy from the verbatim original with
`--remove-info --remove-metadata --deterministic-id --linearize`; an author who
says no gets the original copied back at claim time, which costs a `File.cp`
rather than a shell-out on the publish path. `--remove-structure` is
deliberately not used (that is the tagged-PDF tree a screen reader follows),
and `/ModDate` survives by qpdf's own design.

That answer travels through `post_drafts.strip_metadata?`, so a reload brings it
back beside the words it was chosen with; it does not count as content, so
flipping it on an empty composer creates no draft.

## The post waits for its files

A post carrying a file is not published until the server is done with every one
of them: rendered, and every preview page past the AI check. That is minutes,
so the submission is parked as a `Vutuv.Posts.PendingPost` and
`Vutuv.Posts.Publisher` turns it into the post the moment the last medium
settles — the row that used to wait for a clip alone (#1910), generalised, with
the clip now one case of it. `Vutuv.Posts.Pending` owns the whole question:

* **`state/1`** asks the clip and every file, and answers `:ready` only when
  none is still working, `:refused` when one can never become ready. The
  composer asks the same module (`files_done?/1`) before deciding whether to
  publish now or park, so the two sides cannot disagree about "done".
* **One author topic**, `topic/1` (`"post_media:<user_id>"`), carries
  `{:post_video, …}`, `{:attachment, …}` and `{:pending_post, …}`, so the
  composer's file chips, the waiting card above the feed, the app-bar chip and
  `/system/uploads` (`VutuvWeb.UploadsLive`) all draw from the same events, and
  `VutuvWeb.PendingPostComponents` words every stage once for all four.
* **A refusal keeps the text.** The AI check deleting a preview page stamps
  `attachments.refused_at` (the file itself is untouched — what happens to a
  file whose *contents* are refused is the upload gate's question), the post
  stops waiting, and the author is offered the text without the refused file
  or neither. Both are `phx-click` events, never links: each destroys state,
  and a state-destroying GET dies on a Back button or a link prefetch.
* **Surviving a deploy.** The publish is claimed by a compare-and-set on
  `status`, and the claim writes `minted_post_id` — the id the post is about to
  get — so a slot killed between the insert and the bookkeeping is resumed by
  finding that post rather than writing the member's post twice.
  `Vutuv.Posts.PendingSweeper` runs `Pending.sweep/1` once a minute as the
  backstop when the nudge from a settling medium died with its process, and
  stamps `checked_at` on **every** row it looks at, including the ones it can do
  nothing for, so a still-rendering file cannot hold the front of every batch.

## A message's files (issue #2110)

A private message carries text alone by design. Between two **connected**
members — vernetzt, two mutual follows, `Vutuv.Social.connected?/2` — it also
carries files and pictures. That one sentence is the whole security argument
for the feature: an unsolicited file from a stranger is the classic malware
channel.

So the gate is **asked three times**, and `Vutuv.Chat.files_allowed?/1` is the
only place that decides:

* when the file is **attached** — the composer offers a picker only where it is
  allowed, and `handle_progress/3` asks the *database* again before it keeps a
  byte, because a connection can end while the composer stands open;
* when the message is **sent** — `Chat.send_message/4` refuses the whole send
  with `{:error, :files_not_allowed}` rather than delivering it with the files
  quietly dropped;
* whenever the **bytes** are asked for — `Vutuv.Attachments.readable_by?/2`, on
  every request through the proxy.

**Ending the connection closes the files again, for both sides.** Nothing is
deleted; the row and its bytes stay and connecting again brings them back. The
reasoning: unfollowing is the only lever this app gives anybody over a
conversation, and a file that stayed readable would leave exactly the
stranger's file the rule exists to keep out. It is symmetric because the
sender's own copy is on their disk anyway, and a one-sided rule would be a
second answer to the same question.

A **page's inbox carries no files at all**: a page is not somebody a member is
vernetzt with, so `files_allowed?/1` reads the nullable pair's columns and
answers false — the fail-closed answer as well as the true one.

**The recipient sees a file only after it has passed**, which is `settled?/1`:
rendered, every preview page past the AI check, not refused, not frozen. The
**sender** sees their own file at every stage with its state beside it, so the
bubble can say what is happening; the other side gets a plain sentence until
then, never silence — the message says something was sent.

A **picture** is an attachment whose single preview page is the picture itself,
on the shared `images` table like any other `attachment_page`: no new kind, no
new upload tree, and the AI scan, the lite version, the regenerator and the
copyright freeze reach it because that kind already has them. It is **not** a
post photo and gets no gallery. The body stays image-free
(`Vutuv.Chat.Message`'s `validate_no_images/2`); the files hang beside it. A
message with files may have an empty body — sending a picture with nothing
written under it is the ordinary case — and the sidebar's one-line preview then
says how many files rather than nothing at all.

**Files stay as long as the conversation does**, and that is a promise about
the disk. The rows cascade with the message on their own; `Vutuv.Chat` calls
`Attachments.purge_for_message/1` before deleting a message and before wiping a
declined request's thread, because a served copy nothing points at is a leak
nobody would notice. (Account deletion is the one gap left, and it is #2111's:
`Accounts.delete_user/1` takes the rows through the cascade and leaves the
bytes.)

### The one address a file has

`VutuvWeb.AttachmentController`, at `/system/attachments/:token/file` and
`/system/attachments/:token/pages/:position/:version`. Under `/system/` rather
than a root word, like the two media proxies beside it, so it burns no handle a
member could otherwise claim. Login-required, and every request re-asks
`readable_by?/2`; denied and unknown are the same 404, so the URL cannot be
used to find out that a file exists. The file is always sent as a **download**
(`content-disposition: attachment`) with `cache-control: private, no-store` —
this URL does not answer the same way for ever, and a copy cached in a shared
browser would outlive the connection that justified it.

A file under a **post** has no address here. #2108 owns that, and until it
lands `readable_by?/2` answers false for the post half: a check that has not
been written is not a check that passed.

## The preview pages

`Vutuv.Attachments.Pages` renders the first pages of a file as pictures, so a
reader can tell what it is without downloading it: three by default
(`ATTACHMENT_PREVIEW_PAGES`), five at most, none at zero.

**A PDF page is rendered by `pdftoppm`, not by libvips.** The issue asked for
libvips' Poppler loader, and that loader is not in this application: `vix`
generates its `Vix.Vips.Operation` functions from the operation table of the
libvips it links, and the precompiled one it ships (8.17.1) has no PDF loader
at all — `pdfload/1` is undefined rather than failing, and `otool -L` on the
bundled library shows no poppler. The Homebrew `vips` CLI on the same machine
*does* list `pdfload`, which is what makes the claim look true from outside.
`pdftoppm` is what this project already renders PDF pages with in three other
places, ships in the same package as the `pdfinfo` the gate needs, and CI
already installs it.

A **text or Markdown** file is rendered as one page: the document goes through
`VutuvWeb.Markdown.render/1` (or a `<pre>` for plain text) and headless
Chromium photographs it, through the raw `Vutuv.PageScreenshot.capture/3` that
moderation evidence already uses. One page, not three, because a text file has
no pagination of its own — what is captured is the first screenful, and slicing
a README into three would produce two pictures of nothing in particular.

That page's content is a member's file, so it is rendered **offline**: the
document carries `Content-Security-Policy: default-src 'none'` and the browser
is launched with `--host-resolver-rules=MAP * ~NOTFOUND` (`offline: true`).
Either alone stops a Markdown image reference from making this server fetch an
address the member chose.

Both are about **subresources**, though, and neither covers top-level
navigation: a `<meta http-equiv="refresh" content="0;url=file:///etc/passwd">`
would navigate and be photographed, because CSP has no navigation directive
here and a `file://` URL asks no resolver anything. What keeps that out is a
layer up — `VutuvWeb.Markdown.render/1` escapes every `<` before Earmark, then
sanitizes, then strips `<img>`, so nothing a member writes becomes a tag at
all. Loosening that pipeline (raw HTML pass-through, another renderer) is
therefore a change to the preview renderer's threat model too, and needs a
navigation answer of its own first.

### Each page is a picture

A rendered page is a row on the shared `images` table of kind
`attachment_page`, parented by `attachment_id` and ordered by `position` — the
second kind **born** on that table (`Vutuv.PressKit` was the first), stored
under the file's own token at
`attachments/<token>/pages/<position>/<version>.avif`.

What that gets it, and what it does not, is worth being exact about, because
five of the six behaviours are per-kind lists rather than generic machinery:

* the **AI scan** reaches it because `attachment_page` is in
  `Vutuv.Moderation.ImageScan.kinds/0` and has a clause each in
  `ImageSubjects`' `source/1`, `apply_approved/1`, `apply_rejected/1` and
  `stranded_pending/0`;
* the **pixelated wait** because `AttachmentStore.store_page/3` writes the
  stand-in;
* the **lite version** because `Vutuv.Uploads.Spec` declares one for
  `:attachment_page` (which has no `xl` — the file itself is what somebody who
  wants to *read* it takes);
* the **regenerator** because `Vutuv.Uploads.Regenerator` names it in four
  places — and it is the one type there with no stored original, so a
  regeneration really re-runs poppler or Chromium;
* the **lightbox** genuinely is generic;
* the **copyright freeze does not reach it yet, deliberately.** Adding a kind
  to `Vutuv.Images`' `@takedown` map makes it reportable by anyone who can name
  a row id, with no visibility check at all — and a preview page can belong to
  a file no post has claimed. #2109 wires the strategy and the visibility clause
  in one change; until then `takedown_ready?/1` answers false and nothing offers
  a report button for a page.

A refused page has its row and its derived sizes deleted and **the file left
alone**: the model judged the picture we derived, not the upload.

### Surviving a deploy

Rendering takes seconds to tens of seconds, so a blue/green deploy stops the
slot in the middle of it. The recovery is `Vutuv.Videos`' shape: the row
carries the state (`stage`), each finished page has its own row so a resumed
render skips it, the due list is a query (`Pages.due/1`) and a claim is a
compare-and-set on `attachments.worked_at`, so two slots cannot render the same
file. `attachments_test`'s sibling kills the render mid-loop and asserts the
sweeper finishes exactly the rest.

`stage` always reaches a terminal value — `ready` (however many pages, zero
included) or `failed` — **including the outcomes where nothing could be done**:
previews switched off, or a host with neither `pdftoppm` nor Chromium. A file
that could not be worked on and stayed due would hold the front of every
oldest-first batch for ever. A strike (`render_attempts`, three of them) is
taken only when the renderer itself ran and failed.

The consequence to know: a file uploaded on a host with no renderer is settled
`ready` with no pages and is **not** re-rendered if poppler is installed later.
`mix vutuv.regenerate` re-derives existing pages, not missing ones.

## The media job

The intake writes one `Vutuv.MediaJobs` row of kind `attachment_intake`, and
the page rendering one of kind `attachment_pages` per file, so
`/admin/media` shows it beside the photo scans and video conversions. A
refusal is a **finished** job with the reason in `detail` — the pipeline did
its work and the answer was no; only a step that could not be run at all is
`failed`.

## Reporting a file (issue #2109)

A file is a content type of its own in the moderation case machinery, the way a
picture is: `attachment` reports, the usual categories, a copyright notice from
a reporter in good standing moving the file — and the preview pages that freeze
with it — into `frozen/` rather than deleting anything, the owner's 72-hour
self-service window, and an upheld case deleting the file while the post keeps
standing. `frozen_at` on this row is the record of that hold;
`Vutuv.Attachments.freeze/1`, `unfreeze/1`, `purge/1` and `reconcile_holds/0`
are the four halves of it, and the whole flow is written up in
[moderation.md](moderation.md).

Two consequences for this document. The file's hold is
`frozen/attachments/<attachment id>/`, one level deeper than a picture's, so
`Vutuv.Images.reconcile_holds/0` cannot mistake it for a stranded image hold and
delete it. And nothing serves a file or its pages yet, so a file has no address:
the public notice form cannot name one and the post's card has no chip to hang a
Report link on until #2108 gives it one.
