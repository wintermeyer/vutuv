# Files on posts and messages

A post can carry files as well as photos and a clip: PDF, plain text and
Markdown to begin with (milestone #2102). This document covers the part that
exists today — how a file gets in — and grows as the rest of the milestone
lands: the preview pages (#2105), the post that waits for them (#2106), what
a post shows and hands out (#2108), reports and copyright (#2109), messages
(#2110).

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
`ATTACHMENT_MONTHLY_MB`, `PDFINFO_PATH`, `PDFDETACH_PATH`.

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

## The media job

The intake writes one `Vutuv.MediaJobs` row of kind `attachment_intake`, so
`/admin/media` shows it beside the photo scans and video conversions. A
refusal is a **finished** job with the reason in `detail` — the pipeline did
its work and the answer was no; only a step that could not be run at all is
`failed`.
