# Files on posts and messages

A post can carry files as well as photos and a clip: PDF, plain text and
Markdown to begin with (milestone #2102). This document covers the part that
exists today — how a file gets in and how its preview pages are rendered — and
grows as the rest of the milestone lands: the post that waits for them (#2106),
what a post shows and hands out (#2108), reports and copyright (#2109),
messages (#2110).

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
They are byte-identical today; they are still two files, because the served
copy is what #2107 rewrites when an author asks for the metadata to be
removed, and the private tree's promise — this is exactly what the member sent
— has to survive that. Neither tree gets a `Plug.Static` mount: every served
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
`PDFTOPPM_PATH`.

`ATTACHMENT_UPLOADERS` is `admins` while the milestone is being built, the way
video was introduced: a post cannot show or hand out its files until #2106 and
#2108 land, so nobody else is offered a picker yet.

## The nullable pair

`attachments.post_id` and `attachments.message_id` are the shape CLAUDE.md
warns about: at most one is set, and both are `nil` while the composer holds
the file. `Vutuv.Attachments.pending?/1` is the one place that asks, so a
later reader cannot write its own `is_nil/1` pair and get one of them wrong —
an inner join to `posts` would silently drop every message's file, and a
`NOT IN` over these ids without an `is_nil/1` branch is false for every row.

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

That page's content is a member's file, so it is rendered **offline twice
over**: the document carries `Content-Security-Policy: default-src 'none'` and
the browser is launched with `--host-resolver-rules=MAP * ~NOTFOUND`
(`offline: true`). Either alone would stop a Markdown image reference from
making this server fetch an address the member chose; neither alone fails
closed.

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
