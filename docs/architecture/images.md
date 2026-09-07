# Images

The image pipeline behind avatars, cover photos, URL screenshots and post
images. How post images are uploaded and audience-guarded is part of
[posts-and-feed.md](posts-and-feed.md); this document covers what all images
share.

## The pipeline

Avatars, profile cover photos, URL screenshots, post images and job-posting
images are stored on local disk and processed with
[`image`](https://hex.pm/packages/image) (libvips); see `Vutuv.Avatar` /
`Vutuv.Cover` / `Vutuv.Screenshot` / `Vutuv.PostImageStore` /
`Vutuv.JobPostingImageStore`.

**Every served version is AVIF**; the resolution, crop and quality of every
version live in one module, `Vutuv.Uploads.Spec`, so a future format/compression
change is a Spec edit plus one `mix vutuv.images.regenerate` run — the
regenerator (`Vutuv.Uploads.Regenerator`) covers all five types, including
`job_posting_images`.

### The lite versions (data-saving mode)

Four types carry a **`lite`** version beside their display version, for a
viewer in data-saving mode (`Vutuv.LowBandwidth`, the `low_bandwidth?`
preference): a post photo (640 px beside the 1200 px `feed`), a picture from
another network (640 px beside its 1200 px `image`), a URL screenshot (400×264
beside the 800×528 `thumb`) and a profile cover (800 px beside the 1600 px
`wide`), all at Q40. The sizes are measured, not chosen: over 40 real photos
on the production copy, 640 px at Q40 is 21 % of the `feed` bytes (12 kB
against 44 kB at the median) and the next steps down buy little more — the
numbers sit beside `@lite_quality` in the Spec. Avatars store no softer
version: the 96 px thumb is 1.7 kB, and a Q40 one would blur every name on
the page. The **profile picture** at the top of a profile is the one avatar
slot that offers a lite anyway, out of the versions it already has: the slot
is 96 CSS px and loads the 192 px `medium` for HiDPI screens, so the 96 px
`thumb` is that same picture at 1x (`Vutuv.Avatar.picture/1`, asked by
`VutuvWeb.UI.avatar/1` for the `lg` slot alone — 2 kB against 6 kB). No new
file, no regeneration; a list avatar already loads the thumb and gets nothing.

The mode is a **per-process flag**, not an argument: which version an `<img>`
loads is decided deep inside a component that has no business being handed
the viewer, so `Vutuv.LowBandwidth.on?/0` lives in the process dictionary
beside the Gettext locale and the viewer clock and is written by the same two
writers (`VutuvWeb.Plug.Locale`, `VutuvWeb.LiveLocale`). An embedded child
applies it on its socket alone: the shell mounts in the request process at the
top of the app layout, before the page body renders, and writing the anonymous
default there is what handed every first paint of a LiveView page the
full-size pictures until 2026-09-05 (the viewer clock paragraph in
[settings-and-account.md](settings-and-account.md)). Each store answers one
`picture/…` function — `Vutuv.Posts.PostImage.picture/2`,
`Vutuv.RemoteMedia.picture/1`, `Vutuv.Screenshot.picture/1`,
`Vutuv.Cover.picture/1`, `Vutuv.Avatar.picture/1` — returning `%{src:, lite:}`:
the version the page always showed, and the lite only while the flag is on
*and the file exists*. `VutuvWeb.UI.picture/1` renders the pair: without a
lite it is the plain `<img>` it replaced, attribute for attribute; with one,
the lite loads and the **SD/HD switch** in the corner swaps the full version
in on tap (`app.js`, `[data-hd-load]`), leaving a `data-hd-loaded` mark the
LiveSocket carries across every later patch so a like count ticking cannot
blur the picture back. Off that mark the switch hides — from `app.css`
outside every cascade layer, because the switch wears an `inline-flex`
utility and a layered `display: none` never beat it (the switch stayed on
every picture whose HD had arrived for the two days it shipped that way).
The lightbox opens `large` (1600 px) rather than `xl`
(`PostImage.lightbox_url/1`).

**A lite is never a broken picture, and never a blind URL.** Every store asks
the disk before naming a lite (`Vutuv.LowBandwidth.picture/2` runs the probe
only for a viewer in the mode), so a row the regeneration has not reached
keeps showing its full version. The post photo does this too although its
proxy could fall back the way `xl` falls back to `large`: the proxy caches
every version as immutable for a year, so a lite URL answered with the feed
bytes would stay the feed for that year, on exactly the member the mode is
for. A remote picture keeps no original, so only pictures fetched after the
version existed have one (`lite-<hash>.avif`, the same hash as the picture,
opened by the same proxy rules). Adding the version made every row
non-converged, so the deploy's `regenerate_images` step re-derives them all
once — screenshots included, a few minutes after the traffic switch.

The **pixelated preview** of a picture still being checked is the one thing
the mode drops entirely rather than shrinks: `Pixelation.stands_in?/2` answers
false for a viewer in the mode, so the three renderers that ask fall back to
the grey hourglass tile they already have for installations without previews.
The preview is 64 blocks blown up to 960 px and costs about what the finished
picture's lite does (13 kB against 12 kB on one photo), for the minutes a scan
takes; serving is not gated, so a preview URL rendered earlier keeps answering.

Not covered, on purpose: a picture placed **inline in a post body** (the
`![](…/feed.avif)` reference `VutuvWeb.Markdown` renders, 10 posts on
vutuv.de) and the composer's own upload previews still load the full version.
The inline image is a string the Markdown renderer builds, and a second copy
of the switch's markup there would be the drift the component exists to
prevent.

Pending gallery uploads (a composer that was never submitted) are swept after a
day by `Vutuv.Posts.PendingImageSweeper`, which cleans **both** the post and the
job-posting galleries (rows and files).

### SVG (organization logos)

An **organization logo** may also be uploaded as SVG — the one picture members
usually hold as a vector. `Vutuv.Uploads.Spec` rasterises it on the way in (at
`svg_raster_size/0`, the widest version an organization image is stored at); the
served versions are AVIF like every other picture, and the SVG stays behind as
the original.

*It is decided by content, never by filename.* What `open_rotated/1` is handed
is the upload's temporary file, which has no extension, and libvips picks its
loader by content anyway — so a `.png` full of SVG markup renders as SVG
whatever the whitelist believed. The opening bytes decide instead.

*The renderer is what is protected, not the browser.* No SVG is ever served, so
this is not an XSS question: the XML parser runs on our machine, on markup a
member — or a remote server — chose, and it will expand entities (XXE, billion
laughs) and follow references while rendering. The gate refuses a DOCTYPE,
entity, `<script>`, `<foreignObject>`, `javascript:`, `@import`, or a `href`
pointing at `http(s):`, `file:` or `//`, and it sits inside **both**
`open_rotated/1` and `open_rotated_binary/1` — the two doors every picture comes
through — so it covers a fediverse attachment and an Open Library cover as well
as the upload form.

Availability is a property of the box: SVG needs librsvg inside libvips, the way
`.heic` needs an HEVC decoder. `Spec.svg_supported?/0` answers that by rendering
a probe (a registered loader is not proof — see `heic_supported?/0` next door);
the whitelist and the hint under the upload field are built from it, and
`spec_test.exs` asserts it beside the AVIF guard, so losing it is loud.

Every uploaded **original** is kept verbatim (format + metadata) under the
private `<UPLOADS_DIR_PREFIX>/originals/` tree (`Vutuv.Uploads.Originals`) as
the source for re-deriving. It is not reachable by URL construction (no
`Plug.Static` mount, no nginx alias; a regression test enforces this). The one
deliberate exception is the per-photo post-image download an author switches on
themselves — see [Original downloads](#original-downloads-issue-1104) below.

## Opening a picture at full size (the lightbox)

Two pictures are meant to be *looked at* rather than to fill a layout slot, and
both have a version sized for that: a post photo's `xl` (2560) and an avatar's
`large` (1024, issue #1528). Both open in the same overlay
(`assets/js/lightbox.js`), a page-level enhancement appended to `<body>` outside
every LiveView root; a click target only has to sit inside a
`<.lightbox_gallery>` (`VutuvWeb.UI`, which carries the overlay's own translated
chrome wording) and name what it shows in `data-photo-*` attributes.

The avatar's `large` is `{:crop_down, 1024, :center}`, not `{:crop, …}`: it stays
square like the `thumb`/`medium` beside it but never upscales, because an avatar
is the one upload members routinely hand us smaller than the version we want.

**A new version is not there the moment its code deploys.** `fingerprint_converged?`
counts every Spec version as a file on disk, so adding one makes every row
non-converged and the deploy's own `regenerate_images` step re-derives them —
but that runs *after* the traffic switch, and a row whose original went missing
is skipped forever. So the profile header asks the disk
(`Vutuv.Avatar.large_url/1`) and renders the plain, unclickable avatar while the
answer is nil. That one `File.exists?` per profile render is what replaces the
alternative, a two-deploy rollout with a link to a 404 in between.

## EXIF: what is read, and what never is

`Vutuv.Uploads.Exif` reads a **whitelist** of seven camera facts out of an
uploaded photo — camera, lens, focal length, aperture, shutter, ISO and capture
time — into `post_images` columns. Everything else a camera writes (maker
notes, serial numbers, owner name, software trail) is never looked at, so a new
proprietary tag cannot leak through a rule that has not heard of it.

**GPS coordinates are never parsed.** `Exif.gps?/1` answers only *whether* the
file carried a location, which is what lets the composer warn an author before
they hand out the byte-identical file. There is no latitude/longitude column
and no code path that reads one.

Reading happens **before** `Image.autorotate/1`: rotating rewrites the header
and on some libvips builds drops the EXIF block with it, so reading afterwards
returns nothing.

## Original downloads (issue #1104)

A post photo's author can offer the full-resolution file per photo
(`post_images.download_original`). The route is `/post_images/<token>/original.orig`
and it is 404 by default — an unopened download and a nonexistent photo look
identical from outside. It is gated by the post's audience like every other
version.

The author also chooses **which** file:

- **"Just the picture"** (the default) — `Vutuv.Uploads.MetadataStrip` removes
  every metadata block by container surgery: a JPEG's `APPn`/`COM` segments, a
  PNG's non-whitelisted chunks, a WebP's `EXIF`/`XMP` chunks (and the `VP8X`
  flags that advertise them). The compressed image data is copied through byte
  for byte, so it is **not** a re-encode and loses no quality. It is a
  whitelist, not a blacklist. The result is cached at
  `originals/post_images/<token>/cleaned.<ext>`.
- **"The file exactly as I uploaded it"** — the original, untouched.

It **fails closed**: a container the stripper cannot take apart (HEIC) yields
no cleaned copy rather than the untouched file, and
`Posts.update_image_settings/2` forces such a photo to the exact-file choice so
the composer can say so out loud. Never make `MetadataStrip.strip/2` fall back
to returning the input.

Cover photos are uploaded via the Edit profile form and served from
`<UPLOADS_DIR_PREFIX>/covers/` (nginx needs a `location /covers/` alias in
production, mirroring `/avatars/`)

## Fingerprinted avatar/cover filenames

Avatar and cover files are named `<handle>-<version>-<fingerprint>.avif` (e.g.
`swintermeyer-medium-1a2b3c4d.avif`), where the fingerprint is
`sha256(original)[0..11]`.

The handle makes a downloaded file carry the username; the fingerprint makes the
URL immutable, so it needs no `?v=` cache-buster and the **existing** nginx
`alias` serves it directly (no rewrite).

The fingerprint is read off the picture's row in the shared `images` table
(`images.fingerprint`, since #2027); a username change re-derives the files
under the new handle. A picture with no fingerprint has not been migrated to
this scheme yet and serves the legacy `avatar_<version>.avif?v=...` URL
unchanged — one member on the production copy is still in that state, which is
why "no fingerprint" must never be read as "no picture".

The migration is **expand/contract**: the regenerator writes the new files and
**keeps** the legacy ones (so the previous release and a rollback keep serving
them); once the scheme is confirmed healthy in production, `mix
vutuv.images.sweep_legacy` (`Vutuv.Release.sweep_legacy_images()`) deletes the
legacy files — a deliberate, manual step, never part of the deploy

## The shared `images` table (issue #2013)

A post photo has been a row of its own for a long time — a token, an AI gate
verdict, a parent a report can take offline. A member's profile picture and
cover were four columns on the member row each (`avatar` /
`avatar_fingerprint` / `avatar_crop` / `avatar_moderation`, and the cover
four), so every moderation answer about a picture had to be written once per
kind, and a stolen profile picture could only be reported as the whole
profile.

`Vutuv.Images` is where that ends. One row per picture: `kind`, the owner,
an unguessable `token`, the three columns describing the stored file
(`file` / `fingerprint` / `crop`), the gate's `moderation` verdict, and
`frozen_at` for a copyright case (#2012 writes it; a freeze moves files and
never deletes them).

The table arrived **additively**. An upload writes the row *and* keeps filling
all four member-row columns; the member row gained a pointer
(`users.avatar_image_id` / `cover_image_id`). Nothing about how a picture is
stored or served moved — an avatar URL is byte for byte the one it was, which
matters because other servers hold it in their copy of our ActivityPub actor
document, search engines hold it, and sent mail holds it. #2015 moves the
remaining kinds in.

**Since #2027 the row is what every reader consults**, and the four columns per
kind are dead weight the deploy after that one drops. `Vutuv.Images.member_image/2`
is the one door: it takes the `belongs_to` when a caller preloaded it and falls
back to one primary-key lookup on the pointer when nobody did, and answers `nil`
— at no cost — for the 72 % of members who have no picture at all. Everything
downstream reads that row: `Vutuv.Uploads` takes it as `{image, scope}` in place
of the old `{file, scope}`, so `url/3`, `version_path/3`, `regenerate/3`,
`reslug/2` and `sweep_legacy/3` never look at the member row again;
`Vutuv.Avatar` and `Vutuv.Cover` resolve it once per call and hand it down.

**Two things follow from that.** A **frozen** picture is now hidden by
`frozen_at` rather than by the cleared columns (the freeze still clears them,
because the previous release is still serving from them during the blue/green
window) — `Vutuv.Images.shown_image/2` is the reader's door for that, and it
answers `nil`, so a held picture draws the initials tile exactly as a member
who never uploaded one does. A picture the AI gate merely holds is not that
case: it keeps the grey silhouette, because it is coming back. And a
**listing** query has to carry the pointer *and* the two columns the bridge
reads: `Vutuv.Accounts.User.listing_fields/0` selects `:avatar_image_id`
beside `:avatar` and `:avatar_fingerprint`, or a whole page of members would
lose its pictures at once.

**Taking this release does not require the backfill to have been run** — see
the bridge under "The columns go in four steps" below. Run it all the same,
and read `bin/vutuv eval "Vutuv.Release.check_image_rows()"`: it is the gate on
the deploy that removes the bridge and the column writes, and until it is green
a picture with no row is one nobody can report on its own.

Which member-row column holds what is written **once**, in
`Vutuv.Images.member_columns/0`; `Vutuv.Moderation.ImageSubjects` and
`Vutuv.Images.Backfill` read it from there, so the deploy that drops those
columns has one list to delete rather than four copies to find.

Five places write the pair, and they are the only ones that touch the
member-row columns at all: `Vutuv.Accounts.store_pending_image/6` (upload — it
mints a fresh token, because a token names the bytes and a re-upload should
leave a report pointing at nothing rather than quietly at the new picture),
`ImageSubjects.apply_approved/1`, `apply_rejected/1` and `cleanup_canceled/1`
(the gate's verdict and its cancel), and `Vutuv.Uploads.regenerate/3` for the
fingerprint a re-derive produces. That last one keys on the pointer the member
row already holds, so a picture with no row yet costs no statement and the
regeneration pass never *creates* one — that is the backfill's job, not a side
effect of a deploy.

The upload writes its pair in **one transaction**. Apart they could
half-commit: `Uploads.store/4` has already replaced the served files by then,
so a failure between the two writes (a pool timeout, a slot dying in the
blue/green switch, a `StaleEntryError`) left the row naming the new picture,
the member row still naming the old file whose bytes were gone, and no scan
queued to take the row out of `"pending"` — with a success flash on the way
back. For the same reason `:moderate_images` is read once per upload and handed
to `Uploads.store/4`, so the state the row records and the tree the bytes land
in cannot disagree.

### Bringing the older pictures in (issue #2014)

`Vutuv.Images.Backfill` is the contract half — `mix vutuv.images.backfill`, or
`bin/vutuv eval "Vutuv.Release.backfill_image_rows()"` on a release. It moves
no file and changes no URL, so the previous release keeps serving unchanged
while it runs.

It **reconciles**, it does not insert-where-missing: for every member it
compares `file`, `fingerprint`, `crop` and `moderation` against the row and
corrects the row where they differ (with a fresh token when the picture itself
changed), creates one where there is none, and deletes a row whose member has
no picture of that kind any more. Insert-where-missing would skip exactly the
members a half-committed upload had already given a wrong row — the ones whose
truth the column drop is about to destroy.

Work is a keyset scan over `users.id` with one transaction per member and no
state in memory, so a run a deploy kills mid-flight is simply run again: every
member it reached is already right and reports `unchanged` (rehearsed on the
production copy: `kill -9` at 309 of 1,747 pictures left 309 complete pairs and
no half-pair, and the second run created the other 1,438 and corrected none).
`from: "<user id>"` resumes from a progress line instead of re-reading the
table.

Since #2054 the same two commands cover the gallery kinds as well.
`Vutuv.Images.Backfill` has exactly two shapes — `%{cols: …}`, the truth in
columns on a parent row joined by a pointer, and `%{gallery: …}`, the truth in
a row of the picture's own joined by its token — and everything around them
(the keyset walk, the classes, the repair, the sample, the printing, both
operator paths) is shared. A gallery source builds itself from
`Vutuv.Images.mirror_source/1`, so adding a kind touches nothing in the
backfill at all; its repair is the same `mirror/2` upsert the request path
writes, so create and correct are one statement and need no transaction; and
it reports no `missing_pointer`, which the report leaves out rather than
printing as a zero. The one thing to check when the next kind arrives is the
store's `version_path/2` signature: `Vutuv.PostImageStore` and
`Vutuv.JobPostingImageStore` take the row, `Vutuv.OrganizationImageStore` takes
the token, and `Vutuv.Moderation.ImageSubjects.image_path_arg/2` is the adapter
that already knows.

`Backfill.check/1` (`mix vutuv.images.backfill --check`, or
`bin/vutuv eval "Vutuv.Release.check_image_rows()"`) is the gate before the
cut: it counts every picture against its row *and* against its file on
disk — the quarantine tree while the picture is `"pending"`, the served tree
otherwise — prints one line per kind plus a bounded sample of the ids behind
each class of mismatch (`Backfill.check/1`'s own doc names what each class is
sampled by), and **fails the command** when anything is outstanding. Both of
those come from `check/1` itself rather than from either entry point, because
the first version put the printing in the mix task alone: it fell out of step
with the shape `check/1` returns and crashed on every invocation, while the
release path printed nothing and exited 0 with 1,678 mismatches — which reads
exactly like a clean bill of health. A missing file is the one class the
backfill cannot repair; it predates the table and wants a human before the
columns go.

**The columns go in four steps, and the order does not depend on an operator
remembering anything.** #2014 shipped the backfill (the columns still served
everything); **#2027 moved every URL builder and display gate onto the row**,
which is the release this document describes; an operator then runs
`mix vutuv.images.backfill` and reads its check; the deploy after that drops
both the **bridge** (below) and the writes that keep the columns filled; and
only the deploy after *that* carries the migration dropping `avatar` /
`avatar_fingerprint` / `avatar_crop` / `avatar_moderation` and the cover four.
Each step is N-1 safe on its own, and no two can be merged: a migration may
only drop what the *currently deployed* release no longer reads.

**The bridge is what makes the middle two commute.** `Vutuv.Images.member_image/2`
answers in three steps: the preloaded association, then a lookup on the
pointer, then — when there is no row at all — the member row's own four
columns, read as the row they will become (`bridge/3`, an unsaved `%Image{}`).
Without it, taking the #2027 release before running the backfill would render
**every** picture that predates the `images` table as no picture: initials
instead of a face, no `og:image`, no ActivityPub icon, no vCard photo,
`avatar_file: nil` in the GDPR export. Silently — nothing raises, nothing
logs, and the deploy's own `regenerate_images` step would walk 0 rows and
report success. Nothing enforces the backfill: it is not in
`scripts/deploy.sh`, not in boot, not in `/health`. So the columns, which this
release writes anyway, stand in until the deploy that removes both.

Two things follow. `Vutuv.Accounts.User.listing_fields/0` and
`Vutuv.Accounts`' `@admin_listing_fields` carry `:avatar` and
`:avatar_fingerprint` beside the pointer, because a narrow select that omits
them leaves the bridge nothing to read and a whole page loses its faces at
once. And a **bridged picture cannot be reported on its own**: the report form
names a picture by its row id and an unsaved row has none, so
`Images.reportable_image/2` answers nil and the profile's own Report stands in
until the backfill runs — which is all there was before #2012 anyway.

**What the drop deploy can now assume.** No *reader* consults the four columns
per kind. Three deliberate exceptions read them and go with the cut:
`Vutuv.Images.Backfill`, which exists to compare the two copies;
`Vutuv.Images.member_image/2`'s bridge; and
`Vutuv.Images.hide_from_member_row/1`, whose `not is_nil(field(u, ^config.file))`
is a convergence guard on its own write, not a display gate. What *writes* them,
and therefore goes with the migration, is
`Vutuv.Accounts.store_new_image/8`'s `user_attrs`,
`Vutuv.Uploads.regenerate/3`'s `persist_fingerprint/4` (and the
`:fingerprint_field` in both uploader `@config`s), `Vutuv.Images`'
`hide_from_member_row/1` and `show_on_member_row/1` — the freeze's two halves,
which the drop deletes outright — and
`Vutuv.Moderation.ImageSubjects.clear_profile_columns/1` with its two callers'
member-row writes. `Vutuv.Images.member_columns/0` is the one list of the
names. The backfill itself is what the drop retires: it exists to compare the
two copies, and after the cut there is one.

**How a kind is served is a property of the kind, not a column**
(`Vutuv.Images.serving/1`). `:static` means the derived files sit in a public
tree nginx serves straight off disk, nothing asks this application for
permission, and the only off switch is moving the bytes out of that tree —
the quarantine tree the AI gate already uses
(`Vutuv.Uploads.quarantine_dir/1`), which nginx has no location for. `:proxy`
means every byte goes through a controller that authorizes the reader first,
so the row is the off switch. Avatars and covers are `:static`, a job-posting
picture, a post photo and an organization image are `:proxy`; the review
cover #2015 still has to bring will be too.
It raises for a kind nobody has declared, because a picture that inherits a
default is one nobody knows how to take offline.

### The gallery kinds (issue #2015)

A post photo, an organization image, a job-posting picture and a review cover
each kept a table and an uploader of their own, so the `image` report type and
the freeze knew one kind only. They move one kind at a time and three releases
per kind (the sequence is spelled out below), smallest first — a **job-posting
picture** went first (#2054) precisely to settle the shape, the **post photo**
followed (#2052) as the largest of them, and the **organization image** third
(#2053) as the one whose owner is not a member.

**Three of the four are the same shape; the review cover is not.** A post
photo, an organization image and a job-posting picture each have a row of their
own with a `token`, so they move as *gallery* pictures, below. A review's cover
is `cover` / `cover_status` / `cover_moderation` **columns on the review row**
with no token and no table of its own (`Vutuv.Posts.PostReview`), which is the
profile picture's shape, not this one — #2055 lands on `member_columns/0`'s side
of the fence, and `Vutuv.Images.Backfill`'s `%{cols: …}` source is what it
extends. One thing it does share with the three: a report cannot name one of
its pictures until the kind has a strategy in `Vutuv.Images`'s `@takedown`.

**The token is the join key, not a pointer.** #2013 added
`users.avatar_image_id` because a member row had no stable handle of its own;
a gallery row has carried a `token` from the start, `images.token` has been
unique across the whole table since #2013 for exactly this, and a gallery token
is minted once and never re-minted (a re-upload is a different row). So the
`images` row simply repeats the token, there is no reverse pointer to keep in
step, and this kind has no `missing_pointer` class in the check. It also means
the contract deploy drops the old table outright rather than a column at a
time.

**One kind's own column, six shared ones.** `images` gained `job_posting_id`
(nullable — a posting image is uploaded before the posting is saved, and no
other kind has a posting) plus `alt`, `position`, `width`, `height`,
`content_type` and `size_bytes`, taken with the types `job_posting_images`
holds them at (`alt` and `content_type` varchar(255), the rest plain
`integer`). `post_images` and `organization_images` carry those same six under
the same names, so each further kind adds only its own parent column plus
whatever it holds beyond the six. The `images_profile_kind_has_owner` check
constraint was **extended** rather than the nullable `user_id` widened, which is
what #2013's migration asked for; the parent index is **partial**
(`WHERE job_posting_id IS NOT NULL`), because every other kind's row is NULL
there and the waste would multiply by four — Postgres proves `IS NOT NULL` from
the cascade's strict `= $1` and uses it (measured: 16 kB against 48 kB).

**The post photo is the same shape carrying much more (#2052).** It added
`post_id` (nullable and partially indexed, like the posting's) and thirteen
columns of its own: `caption`, the seven camera facts, `has_gps` and the
author's three switches. `crop` is not among them — a profile picture's crop
rectangle column holds exactly what a photo's does. **Almost every column of
`post_images` is mirrored, and the reason is the third release rather than this
one**: it drops that table, the second adds no migration, so a column left out
now is a column lost then. Three types are worth naming. `caption` is `:text`
on both sides, because a photographer's note runs to 1,000 characters through
the composer and a varchar(255) copy would raise Postgres 22001 from
`Vutuv.Images.mirror/2` — on the *write* path, where no changeset validation
stands between the member and the error. The camera facts are display
primitives in varchar(255) (`f/1.4`, `1/250 s`, `35 mm`), because that is the
notation they are rendered in. And the four flags are `NOT NULL DEFAULT false`
on `post_images` but plain nullable booleans here: an avatar row has no opinion
about a camera panel, and NULL is how it says so.

**The organization image is the same shape with a different owner (#2053).**
It added only two columns, because the six every gallery row shares were
already here at exactly the types `organization_images` holds them at. What it
did have to answer is *who owns a page's picture*, and the answer is not the
member who uploaded it. `organization_images.user_id` is nullable and
`ON DELETE SET NULL` on purpose — a page's logo outlives the account that
uploaded it, which is why `Vutuv.Accounts.delete_user/1` deliberately does not
collect these files the way it collects a member's own. `images.user_id` means
the opposite: a member owner, `ON DELETE CASCADE`, and NOT NULL for every kind
in `images_profile_kind_has_owner`. Copying the uploader into it would
therefore have deleted a page's logo row the day its uploader closed their
account — silently, and only the release that *reads* that row would have
noticed, by drawing the page with no logo. Calibrated by putting the uploader
in `user_id` once and watching the test go red with the mirror row gone.

So this kind's owner column is **`organization_id`** (nullable, partially
indexed, cascading like the other two parents), the uploader rides in
**`uploader_user_id`** with its source's `ON DELETE SET NULL`, and `user_id`
stays empty for the kind under a check constraint of its own,
`images_organization_kind_has_no_member_owner`. That constraint is not
decoration: `mirror/2` writes through `insert_all`, so nothing else stands
between a future author who "fixes" the empty `user_id` and the cascade. It is
also why this kind does **not** join `images_profile_kind_has_owner` — an
organization is not a member, and that list means "names a member".

`uploader_user_id` is the one column in the whole registry whose name differs
on the two sides, so `@mirrored` carries a `:renamed` map for it and
`Vutuv.Images.mirror_attrs/2` is the single place a field is read off a source
row — the copy and the backfill's "has it drifted" comparison both go through
it, because a `Map.take/2` on the source would have skipped the renamed column
in silence and called a drifted uploader "already right". The pairs are
resolved once at compile time, so neither the attach loop nor the backfill
looks a rename up per row.

One thing the three stores did not agree on: `Vutuv.OrganizationImageStore`'s
`version_path/2` took a bare token while the other two take the gallery row, so
every caller that walked the kinds generically kept a clause for it. That store
now answers either, and the clause is gone from both callers — the only change
this release makes under `lib/vutuv/uploaders`, and a pure addition.

**What step 2 needs to know about this kind.** An organization cannot be
struck, warned or suspended the way a member can, so the profile strategy in
`@takedown` does not simply point at it: freezing a page's logo means moving
its files out of the proxy's reach and clearing `organizations.logo`, and the
notice goes to the page's owners (`Vutuv.Organizations.owners/1`), not to
`images.user_id`, which is empty. The uploader is what
`Vutuv.Moderation.ImageScans.privileged_viewer?/2` and the "an unattached
upload is visible to its uploader" branch of
`Vutuv.Organizations.image_visible_to?/2` read today, and both will have to
read `uploader_user_id` rather than `user_id` when they move onto the row.

**One column stays behind, and it has a consequence for step 2: `inserted_at`.**
The mirror stamps its own (`mirror/2` mints the row), which for a photo
uploaded from #2052 on agrees with the photo's to the second — but a
*backfilled* row's says when the backfill ran. The one reader that cares is the
pixelated stand-in the AI gate shows while a picture waits:
`Vutuv.Posts.image_pixelated_url/1` measures its window
(`Vutuv.Moderation.Pixelation.window_seconds/0`) from the **upload** time, and a
row that claims to be minutes old when the photo is months old would put an
expired mosaic back on the page. So the release that moves the readers has to
take that time from the photo rather than from the mirror — either by carrying
`inserted_at` through `mirror/2` for this kind, or by leaving the window on the
old row until the table goes. Nothing today reads it, which is why it is
written down here rather than fixed there.

**The double write is one upsert and one delete.**
`Vutuv.Images.mirror/2` takes one gallery row or a list of them and upserts on
the token — one statement however many, so saving ten pictures costs one — and
`Vutuv.Images.forget/2` deletes by token. The attach path is where the list
form earns itself: `Vutuv.Posts.attach_images!/2` claims each photo with its
own `UPDATE … RETURNING`, because each carries a different `position`, then
hands the whole gallery to one upsert. `Vutuv.Images.write_mirrored/2` pairs
a write with its mirror in one transaction, which is the door a context's own
insert and update go through. `Vutuv.Images.mirror_source/1` is the **one**
per-kind registry — the copied columns, the source schema, the store — so a
kind cannot be mirrored on the request path and invisible to the backfill,
whose check would otherwise print *"Safe to cut"* for a kind it never looked
at. The names are identical on both sides, so the copy is a per-field
`Map.fetch!/2`: a listed name the source lacks raises. The other direction — a
column added to a mirrored table and never listed — nothing can see, so a
drift test over every mirrored kind compares each schema against its list and
fails the build, which also covers the kinds still to come the day their entry
lands.

Every place that writes such a picture goes through one of those: the upload
and every edit (`write_mirrored/2` — for a photo that is the alt text, the
per-photo panel and the crop), the attach and detach on save, the pending
sweep, and the AI gate's approve and reject in
`Vutuv.Moderation.ImageSubjects` — which asks `Vutuv.Images.mirrored?/1` first,
so the next kind's release is one entry in `Vutuv.Images` and nothing there. A
deleted parent or member needs no call: `images.job_posting_id`,
`images.post_id`, `images.organization_id` and `images.user_id` cascade and
`images.uploader_user_id` nilifies, exactly as the gallery table's own columns
do — including the one that deliberately does not cascade. **The `frozen_at` column is deliberately outside the upsert's
replace list**, so an ordinary write can never lift a takedown.

**What an interruption leaves, and it differs by kind.** For a job-posting
picture the upload and the alt edit are atomic, but the attach-and-prune on
save is not and never was — it runs after the save — so a slot dying between an
attach and its mirror leaves a `mismatched_row` (the parent disagrees) and one
between a prune and its `forget/2` leaves an `orphan_row`. Both are classes the
backfill names and repairs; neither is invisible. **A post photo has neither
window**: `Vutuv.Posts` claims and prunes its photos *inside* the save
transaction (`attach_images!/2` and `apply_update!/3`), so the mirror rides
along in it and an interrupted save leaves neither half. The one write outside
a transaction there is the pending sweep, which deletes row, mirror and files
in that order — an interruption leaves an orphan mirror row, then orphan files,
never a row naming bytes that are gone. **An organization image has one
window**, the same shape: `store_logo/4` writes row and mirror in one
transaction, but the displaced logo is purged in three statements (old row, old
mirror, files), so a slot dying between the first two leaves an `orphan_row`
and between the second and third leaves orphan files. Both are what the
backfill and `Vutuv.Uploads`' sweeps already name.

**Nothing reads the new row yet, and that is the whole of the expand half.**
Every URL is the one it was (`/job_posting_images/<token>/<version>.avif`,
`/post_images/<token>/<version>.avif`, `/organization_images/<token>/<version>.avif`
and the photo's `og.jpg`, `original.orig` and pixelated siblings), the
authorizing proxies still work off the old tables
(`VutuvWeb.JobPostingImageController`, `VutuvWeb.PostImageController`,
`VutuvWeb.OrganizationImageController`), and the forms, the feed, the API and
the agent documents still render from `posting.images`, `post.images` and
`organizations.logo` — so no render path pays a query for the mirror, which
matters most on a feed that draws many photos at once. No file under
`lib/vutuv_web` or `lib/vutuv/uploads` changed for any of the three, and the
one change under `lib/vutuv/uploaders` is the extra `version_path/2` clause
described above, which takes nothing away. The consequence to know: `Vutuv.Images.freeze/1`,
`unfreeze/1` and `purge/1` **raise** for such a row rather than half-hiding
it, and `Vutuv.Moderation` refuses a report that names one
(`Vutuv.Images.takedown_ready?/1`), because a case opened on a row nothing
consults would go through an uphold that takes nothing offline. A member
reports the posting instead, which is all there was before the row existed.
That gate reads `@takedown`, the map naming which kinds have a takedown at all,
so it turns yes in step 2 below and not a moment earlier (issue #2057).

**A gallery kind moves in three releases.** #2054 was the first for
`job_posting_image`, #2052 for `post_image` and #2053 for
`organization_image`. Each is N-1 safe on its own and no two can be merged;
this milestone has already paid for an off-by-one in that count once, in #2027.

1. **Expand**: what #2054 shipped for `job_posting_image`, #2052 for
   `post_image` and #2053 for `organization_image`. Every path that touches the picture writes and drops the
   `images` row beside the old one, while every reader, and the truth, stay in
   the kind's own table. Nothing here can take such a picture offline yet:
   `freeze/1` raises for the row and a report cannot name it. Between this
   release and the next, an operator runs
   `mix vutuv.images.backfill --only <kind>` and reads its check; after step 2
   the two copies can no longer be compared, so this is the last chance.
2. **Move the readers, the writes and the takedown onto the row.** The proxy,
   the edit form and the AI gate read the `images` row, and the context writes
   that row directly, so the mirror goes out in the same change: the
   `write_mirrored/2`, `mirror/2` and `forget/2` calls and the kind's entry in
   `@mirrored` (`Vutuv.Images.mirror_source/1`, `mirrored?/1`). *The backfill
   needs nothing removed*, at this step or any other: `Backfill.kinds/0` is
   `Vutuv.Images.mirrored_kinds/0` plus the profile kinds, and every gallery
   source builds itself from `mirror_source/1`, so it holds no per-kind list of
   its own. The kind also gets its takedown here: a strategy in `@takedown` and
   the `freeze`/`unfreeze`/`purge` clauses that go with it, which is what opens
   the report form on these pictures. No migration in this release: the old
   table is still standing and the release one step back is still reading and
   writing it.
3. **Contract**: the migration that drops the kind's own table, and nothing
   else. Step 2 is what stopped using the table, and step 2 is what serves
   while this migration runs.

**No expand release needs a bridge.** #2027 needed one because it moved every
reader onto the row in the same deploy as the row's first appearance, so a
picture the backfill had not reached would have rendered as no picture at all.
Here no reader has moved: a picture with no mirror row is served exactly as
before, by its own table, so an installation that never runs the backfill sees
nothing change. The bridge question belongs to the release that moves the
readers, and it will have a simpler answer than #2027's — the old row *is* the
picture, so the fallback is a lookup in the table it is about to leave rather
than four columns read as a row.

### The takedown hold (issue #2012)

A copyright freeze **moves** a picture, it never deletes one, and the tree it
moves into is `frozen/<image id>/`, keyed by the `images` row rather than by
the storage dir (`Vutuv.Uploads.hold_dir/1`). Inside it, one subdirectory per
tree the files came out of — `served/`, `original/`, `quarantine/` — so a
release puts every file back where it was under the name it had, and the URL
comes back unchanged. Like the quarantine tree, nginx has no `location` for it,
so a byte in there is unreachable however a display helper is fixed later; a
root of its own rather than a corner of `quarantine/`, because both holds move
*everything* in a directory and sharing one tree would mean the AI gate's
release handing a frozen picture back to the world.

`Vutuv.Images.freeze/1` and `unfreeze/1` are the two halves, `purge/1` the
deletion an upheld case (or the owner's own "remove it") performs. What each
one does to the member row is in [moderation.md](moderation.md). Since #2027 it
is `frozen_at` itself that a reader notices — `Vutuv.Images.shown_image/2`
answers `nil` for a held picture — and the member row's four columns are still
cleared beside it so the release one step back, which is serving from those
columns while the blue/green switch runs, hides the picture too.

**A half-finished move is finished by itself.** The row's `frozen_at` is the
*intent* and the disk is the state, so the stamp is written before the first
file moves and the hold is removed only after the member row names the files
again — either way a slot that dies mid-move leaves work that is still visible
as work. `Vutuv.Images.reconcile_holds/0` re-asserts it in both directions
(`Vutuv.Moderation.Sweeper`, every 15 minutes): a frozen picture gets its
member columns cleared again and whatever is left of it moved into the hold, a
hold whose row is no longer frozen is released, and a hold whose row is gone —
an upheld case interrupted between the two — is deleted. Every step is the same
idempotent function the request path runs, so a second pass over finished work
writes nothing, and each file travels by its own atomic rename, so no file is
ever in two places at once. The window is fifteen minutes and that is
deliberate: the columns are cleared in one statement first, so an interrupted
freeze has already taken the picture off every page and only a direct URL to a
not-yet-moved file still answers.

**`Vutuv.Images.Backfill` skips a frozen row.** Its member columns are *meant*
to be empty, so the orphan sweep would otherwise delete the only record of what
the case is about and what an unfreeze has to write back.

## URL screenshots

URL screenshots are rendered by local headless Chromium, wrapped in a browser
window frame (`Vutuv.BrowserFrame`); see `Vutuv.PageScreenshot`. Needs a
`chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on
`$PATH`)

Three surfaces ask for one, all storing through `Vutuv.Screenshot` and gated by
`:generate_screenshots`: a member's **profile link** (`urls.screenshot`, captured
on save and swept, below), a **post's single link** (`post_screenshots`, a durable queue, see
[posts-and-feed.md](posts-and-feed.md)) and an **organization's homepage**
(`organization_screenshots`, the same queue shape, see
[organizations.md](organizations.md)). They differ in one preflight: the link and
homepage paths **follow** redirects to their destination
(`PageScreenshot.capture_resolved/2`, every hop SSRF-vetted), because an apex
redirecting to `www.` is the normal shape of a homepage; the post path insists on
a plain HTTP 200 (`Vutuv.Posts.Screenshots.ensure_http_ok/1`), because there a
redirect usually means a shortener or a login wall.

### The profile link's standing retry

The link form's capture is fire-and-forget (`PageScreenshot.generate_async/1`),
which is the fast path and never the guarantee: a blue/green deploy stops the
slot mid-capture without a word, and a link created by any other path — the
LinkedIn import inserts them straight through `Repo` — had nothing capturing it
at all. Both left the member a grey camera tile for good; 15 of the 1,938 links
on vutuv.de sat like that, most in same-second batches an import left behind.

So the row is the record of unfinished work and `Vutuv.PageScreenshot.Sweeper`
acts on it: every five minutes it captures `PageScreenshot.due/1`, up to five
links, least recently attempted first. `urls.screenshot_attempted_at` is
stamped before each capture and on every outcome — that is the sweeper's clock,
not a claim that anything was captured, and without it the one link that can
never be shot sorts to the front and spends every batch (the deadlock that
stalled `Vutuv.Fediverse.refresh_counts/1`, #1316). It rides `:generate_screenshots`
like the captures themselves, so an air-gapped installation runs no sweeper.

Three things keep a link out of that query for good: `broken?` (an SSRF-refused
target), a `screenshot_moderation` of `"rejected"` (the AI scan threw the
picture out, and re-shooting it every six hours would be a treadmill), and
simply having a screenshot.

`broken?` had to be cleaned up before it could carry that weight. Until v5 the
pipeline flagged **every** failure with it — a missing Chromium binary, a
timeout, a site down that afternoon — and nothing ever cleared it, so vutuv.de
carried 45 links flagged between 2016-12 and 2018-03, none of which resolves to
an internal address today. They are ordinary member homepages that a rule which
no longer exists poisoned, and the sweeper would have stepped over them forever;
`clear_stale_broken_flag_on_urls` sets them back to NULL. A link that really is
an internal target costs one DNS lookup on the next sweep and is flagged again. Which is why **editing a link's URL clears it**
(`Url.changeset/2`): otherwise the row keeps a photograph of a different page
and, having one, is never captured again. The LinkedIn import nudges the
member's own waiting links after its transaction commits
(`capture_missing_async/1`, one task for the batch), so the pictures arrive
while they are still looking at their fresh profile.

### How the browser is driven

Over the **DevTools protocol** (`Vutuv.PageScreenshot.Cdp`), not by
`chromium --screenshot <url>`. The one-shot command line had to go because it
runs no extensions and takes no injected script, so there was nowhere to put a
consent blocker — and a capture of a European page is more often than not a
picture of a cookie dialog. (Verified, not assumed: an extension loaded with
`--disable-extensions-except` / `--load-extension` never injects at all under
`--screenshot`, in either the main or the isolated world. That recipe is for
Puppeteer, which drives a browser-mode Chromium over this same protocol.)

The transport is `--remote-debugging-pipe`: NUL-terminated JSON on file
descriptors 3 and 4. A port only ever gets 0 and 1, so Chromium is launched
through `/bin/sh` with those duplicated across (`3<&0 4>&1`) and its own stdio
sent to `/dev/null` in the same redirection list — fd 4 is a dup of stdout, so
its log lines would otherwise arrive interleaved with protocol frames. No
websocket client, and so no new dependency. The `timeout` wrapper around the
process is unchanged, and remains the thing that stops a wedged Chromium
becoming an orphan.

**When the shutter falls** is adaptive, under a hard 20s ceiling from
navigation (the guarantee `--timeout` used to give: a page whose network never
settles still yields the image it has rendered). A page with no consent dialog
is shot shortly after load; one with a dialog is shot once autoconsent reports
it has finished, plus a moment for the removal to paint; a dialog that never
resolves gives up after 10s instead of burning the whole budget.

### The consent blocker

`Vutuv.PageScreenshot.Consent` injects `@duckduckgo/autoconsent` into every
frame at document start. It detects the site's consent manager, hides it, and
clicks **reject** — never accept, because consenting to tracking on a member's
behalf is not ours to do.

It is opt-in per capture (`consent: true`), and only the link-preview paths ask
for it. `Vutuv.Moderation.EvidenceScreenshot` deliberately does without: that
capture is a record of what a reported member actually posted, and a
third-party script that hides elements and clicks buttons over it — one that
updates itself with `npm update`, unreviewed — is not what evidence should be.

The bundle and its rule set are vendored into `priv/chrome/autoconsent/` by
`mix vutuv.autoconsent.vendor`, the last step of `mix assets.setup`; both files
are gitignored, so `npm update` keeps the CMP rules current. A tree that never
ran it has no blocker and captures dialogs as before: this **fails open** on
purpose, because dismissing a dialog is cosmetic and a shot of the banner beats
no shot at all. (The SSRF egress control below is a different matter and fails
closed.)

Two things about the integration are worth knowing, because each one failed
*silently* — no error, just a capture that looked like autoconsent had no rule
for the site:

- **Consent dialogs live in another origin.** Both sites this was built against
  serve theirs from a Sourcepoint iframe (`cdn.privacy-mgmt.com`,
  `cmp.heise.de`), which Chromium isolates into a target of its own; a session
  attached to the top frame neither sees it nor can script it. So every target
  is auto-attached as it appears and set up identically, and each frame's
  requests are answered **in its own session**.
- **The bundle reaches its host through a function it captures at document
  start**, before CDP has installed the binding, and a CDP binding takes
  exactly one *string* while the bundle passes an object. Both are fixed by the
  shim in `Consent.script/0`; without the serialisation the very first call
  throws inside the bundle's constructor and it never installs itself.

What it does **not** fix is a **consent-or-pay wall**: heise offers no reject
at all for free readers ("Zustimmung erforderlich für kostenfreie Nutzung"), so
autoconsent rejects everything rejectable, reports success, and the dialog
stays. Those pages belong on the blocklist below, which is where heise already
is.

One exception skips Chromium entirely: a **YouTube video link** in a post
stores the thumbnail YouTube publishes for every video instead
(`Vutuv.YoutubeThumbnail`: keyless oEmbed existence check, then
`maxresdefault.jpg` → `hqdefault.jpg`), frameless — the thumbnail YouTube
publishes beats anything a capture of the watch page could produce, and costs
no browser run at all. Any fetch failure falls back
to the ordinary capture; see the link-screenshots section in
[posts-and-feed.md](posts-and-feed.md).

Some pages still never yield a useful shot — a login wall, a bot check, or a
consent-or-pay wall the blocker above cannot clear — so a **screenshot
blocklist**
(`Vutuv.ScreenshotBlocklist`) short-circuits both paths before any Chromium
run: `blocked?/1` decides, `capture_framed/2` returns `:blocklisted`, and the
post path skips the job entirely at `qualifying_url/1`.

The list is per-installation **data**, edited by admins at
`/admin/screenshots?tab=blocklist` (`screenshot_blocklist_entries`, cached in
`:persistent_term` by `Vutuv.ScreenshotBlocklist.Cache`, reloaded over PubSub
so every node picks an edit up). `:screenshot_blocklist` in `config/config.exs`
— `reddit.com` and `heise.de`, or `SCREENSHOT_BLOCKLIST` from the environment —
is only the seed the creating migration copies in. An entry is a domain
(`heise.de` / `*.heise.de`, matched at the label boundary, so `www.` and every
other subdomain is covered but `notheise.de` is not) or a URL
(`example.com/news`, `example.com/*/private`, `https://example.com/story-1`,
matched by whole path segments, with scheme, port, query and fragment ignored).

### The list writes itself: `Vutuv.ScreenshotBlocklist.Vision`

A hand-written list only ever holds the sites somebody noticed. The nine
entries this installation had accumulated by 2026-09 missed zeit.de, faz.net,
golem.de and sueddeutsche.de, each of which answers a capture with a
full-screen consent-or-pay wall. So every fresh capture is judged, between the
shot and the browser frame, by the same local Ollama vision model that
moderates images (`:ollama_vision_model`, `:screenshot_page_check`), on one
question: does this picture show the page, or something in front of it?

The answer splits three ways, and the split is the whole design:

| verdict | what it says | what happens |
| --- | --- | --- |
| `usable` | the page is visible | the capture is kept, the host is remembered as fine |
| `consent` `ads` `login` `paywall` `captcha` | a property of the **site** | the host goes on the blocklist (`source: "ai"`, the model's sentence as the note, the capture copied into `screenshot_evidence/` as evidence) and the capture is discarded — `capture_framed/2` answers `{:error, :obstructed}`, which all three queues treat as permanent |
| `error` `blank` | a property of this **attempt** | only the capture is discarded (`{:error, :unusable}`, transient, retried) — an unreachable host is not a reason to silence a site forever |

`screenshot_page_checks` is the memory: one row per host with the verdict, the
model's sentence, the judged URL and the model's name. A `usable` verdict
stands for `recheck_after_days/0` (90), so the site behind 1,175 of this
installation's 2,026 stored captures costs one inference rather than 1,175,
and a site that adds a consent layer next quarter is still caught. An
`unknown` row is the third state, and it exists for the sweeper-clock trap:
a host whose picture cannot be decoded must still leave the due list, or an
oldest-first queue spends every batch on the one item that can never finish.

Two asymmetries against the image scan it borrows its machinery from. This
check **fails open** — no verdict, no Ollama, an unparseable answer, and the
capture is simply kept; the worst case is a cookie dialog in a preview for one
more day, while a blocklist entry silences a whole site for every member. And
a `blocked` answer is confirmed by `:screenshot_check_votes` independent
opinions (all must agree) before it is acted on, while `usable` is believed on
one, so the common path is exactly one inference.

`Vutuv.ScreenshotBlocklist.Backfill` + `.Sweeper` do the same for the captures
taken before any of this existed: per **host**, judging the stored thumb
rather than shooting the page again, and purging the stale previews of a
freshly blocked site. An admin removing an automatic entry
(`/admin/screenshots?tab=blocklist`, where such lines are marked *Automatic*
and link to their evidence through `/admin/screenshots/blocklist/:id/evidence`)
records a `usable` verdict in the same step — otherwise the next capture would
reach the same conclusion and put the line straight back.

Nothing downstream depends on a screenshot existing: a post shows its plain
link, a profile link renders `<.link_thumb>`'s tile naming the site instead
of the "not created yet" placeholder, and an organization page drops its
website card. Captures taken *before* an entry was
added are not replaced by anything (a link is only re-captured when its URL
changes), so the admin page has a cleanup button —
`Vutuv.PageScreenshot.purge_blocklisted/0` +
`Vutuv.Posts.Screenshots.purge_blocklisted/0` +
`Vutuv.Organizations.Screenshots.purge_blocklisted/0`, also reachable headless as
`bin/vutuv eval "Vutuv.Release.purge_blocklisted_screenshots()"`.

The capture browser sends vutuv's own `User-Agent`
(`Vutuv.SocialFeed.Http.user_agent/0`), the same string the HTTP preflight
probe uses, so a site sees one agent for both requests. It also lets our own
pages recognise a capture: the shot renders the document **from the top**, so
a page that scrolls itself on arrival is shot before those tiles are
painted and stores a blank image — which is why the post permalink drops its
thread auto-scroll for that agent (issue #1033,
`Vutuv.SocialFeed.Http.own_agent?/1`). Keep new on-arrival scroll/focus
behaviour off the capture path for the same reason.

### SSRF egress control (GHSA-mmjf-8cwc-6vwv, CWE-918)

The captured URL is member-supplied, so headless Chromium is a
server-side-request-forgery risk: left to itself it resolves DNS and follows
redirects, `<meta http-equiv="refresh">` and JavaScript navigations, and could
be steered onto `169.254.169.254`, `127.0.0.1:<port>`, or any LAN host and
publish the rendered result on the attacker's own profile/post card. Validating
only the seed URL does not help — the browser is what does the fetching.

The guard therefore constrains Chromium itself: **all of its egress runs
through `Vutuv.Ssrf.SocksProxy`**, a loopback SOCKS5 proxy in the application
supervision tree. Chromium treats a `socks5://` proxy as remote-DNS (it sends
each hostname to the proxy inside the CONNECT request instead of resolving it
locally), so the proxy can resolve-and-vet **every connection** — the seed
page, each subresource host, any redirect / meta-refresh / in-page-navigation
target, and IP literals — through `Vutuv.Ssrf.vetted_address/1` /
`internal_ip?/1` right before dialling it, and dials exactly the IP it vetted
(no second lookup, so no check-vs-fetch DNS-rebinding window). Internal
targets are refused per connection. A companion
`--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE 127.0.0.1` (Chromium's own
documented SOCKS recipe) makes any name resolution *outside* the proxy fail,
and `Vutuv.PageScreenshot` refuses to launch Chromium at all when the proxy
is down (`:proxy_unavailable`) — every degraded path fails closed.

The proxy replaced the original egress control, `--host-resolver-rules=MAP *
<vetted-ip>` (v7.141.2): pinning **every** name to the seed's IP was equally
safe but sent every *subresource* host there too, and most large sites serve
CSS/JS from a separate CDN domain — GitHub's `github.githubassets.com` fetches
died on a certificate mismatch, so every GitHub link card screenshotted as
bare unstyled HTML. Per-connection vetting keeps the same guarantees while
letting cross-host assets load from their real (vetted) addresses.
`Vutuv.PageScreenshot.capture_framed/2` still resolves the seed host once up
front, but only to *classify* it (`:internal_target` poisons the row,
`:unresolvable_target` is retried).

`Vutuv.Moderation.EvidenceScreenshot` calls `capture/3` without the proxy, on
purpose: it shoots this installation's *own* host (a profile/evidence page),
which may legitimately be internal.

The pre-capture probes (redirect resolution on the profile path, the HTTP-200
check on the post path) read only the status line and `location` header, and cap
the response body during receipt with `Vutuv.Http.capped_collector/1` so a
hostile link cannot stream an unbounded body into memory.

## AI image moderation (the Ollama scan)

**Every** image that could become visible to anyone but its owner passes
through one gate before release: member uploads (avatar, cover, post /
job-posting / organization images, qualification proof documents) **and**
the machine-fetched ones — link screenshots and an organization page's homepage
capture (a screenshot of an NSFW page must not bypass the upload gate) and the
book covers on post reviews (`review_cover`, fetched from Open Library by ISBN). A PDF proof document is
judged by its upload-time rendered first page (`scan_page.jpg` beside the
original — the vision model cannot decode a PDF); later pages are covered by
the report/moderation-case path like any other content.
The moderation-evidence screenshots are deliberately exempt — they are
admin-only records of reported content and never public.

The moving parts (all under `Vutuv.Moderation`):

- `ImageScans` — the durable queue (`image_scans` is the job *and* the audit
  row, the `post_screenshots` pattern) plus the display gate `released?/1`.
- `ImageSubjects` — per-kind plumbing: where the bytes live (always the
  private **original**, uncropped, so a crop cannot hide anything from the
  model), how a safe verdict releases and an unsafe one deletes.
- `Ollama` — the vision-model client. The image is downscaled to ≤896 px and
  re-encoded as a stripped JPEG before it is sent; verdicts are forced into a
  JSON schema, and the prompt tells the model to ignore instructions embedded
  in the image. The schema asks for a one-sentence `reason` **first**, so the
  model describes the image before it labels it (that sentence is kept on the
  scan row: after a rejection the files are gone, and the bare category never
  said what the model actually saw). Two error classes: `{:service, _}`
  (Ollama down — retry forever, fail-closed) vs `{:image, _}` (this file
  can't be judged — capped, then rejected; an unverifiable image is never
  released).
- `ImageScanWorker` — boot-resume + poll + nudge, mirroring
  `Vutuv.Posts.ScreenshotWorker`; hourly `repair_drift/0` re-enqueues any
  asset stranded in `pending`, and `ImageSubjects.settle_stranded_quarantine/0`
  settles the **opposite** drift (below).

**Limbo.** A fresh image starts `pending`: the owner sees it (avatar/cover
through the authenticated `/settings/pending_image/...` quarantine preview,
gallery images through the authorizing proxies) with an amber "wird geprüft"
pill; everyone else gets a stand-in — the pixelated preview below where there is one, an
initials tile / gradient otherwise. For the nginx-served kinds (avatars, covers, screenshots) the
derived files wait in `<UPLOADS_DIR_PREFIX>/quarantine/...`, a tree nginx has
no location for, so an unreleased byte is unreachable by URL no matter what a
template renders. Approval moves the files into the served tree; rejection
deletes served + quarantine + original (nothing unsafe stays at rest), clears
the asset's reference and notifies the owner (in-app + email, both derived
from the audit row). Organization logos differ deliberately: the
`organizations.logo` pointer only ever names a released image, so the old
logo keeps showing while the new one is scanned.

**The pixelated preview (issue #1720).** A reader who may not see the picture
yet is shown *the picture itself*, shrunk to 64 cells on its long edge and blown
back up into flat blocks (`Vutuv.Uploads.Spec.write_pixelated/2`, using
`Vix.Vips.Operation.zoom/3` so every block is exactly one source cell).
`Vutuv.Moderation.Pixelation` owns the whole idea — the two filename shapes, the
window, and the "may I show one" question its three kinds all ask. Three things
about it are deliberate:

- **A file, not a filter.** A CSS blur ships the whole picture and asks the
  browser not to show it, which is one devtools click and any non-obeying
  client away from the picture. Here the detail is averaged away before
  anything is stored, so the bytes a reader can fetch carry none of it. The
  test that pins this is a calibrated pair: a 2px checkerboard keeps its
  standard deviation of 127.5 through a served version and comes out at ~0.35
  through the pixelated preview.
- **A short window.** `Pixelation.within_window?/1` stops offering it after
  `IMAGE_PIXELATION_WINDOW_SECONDS` (default an hour, `0` disables previews for
  the whole installation), so a derivative of an unvetted picture never sits on
  a public page indefinitely; the card falls back to the grey tile and the
  release still swaps the picture in whenever it comes.
- **Deleted before the flip.** `apply_approved/1` drops the preview and *then*
  flips the state, because an interruption between the two should cost a reader
  the last seconds of a preview (the grey tile instead) rather than leave an
  orphan file nothing will ever look at again. A rejection wipes the directory.
- **Announced when it is written, not only when it goes** (issue #1927). The
  preview exists for the wait, so the moment it exists is the moment a card
  needs to hear about it: a picture cached from another network and a link
  capture both reach an open page as soon as their bytes are stored, and the
  cards re-read again on the verdict. Announcing only the verdict meant nobody
  watching a feed ever saw a preview — the card was drawn a second before the
  download finished and kept its grey tile for the whole scan.
- **Every surface that draws `<.link_thumb>` hears it** (issue #1928). The
  component draws the same three states on four surfaces, and at first only a
  post's card was told about any of them: a **profile's** Links card and an
  **organization page's** homepage capture (which is absent until there is
  something to show, so its arrival moves the page above the fold) both waited
  for the next load. Each owner module owns the routing for its own rows —
  `Vutuv.PageScreenshot.announce/1` broadcasts `{:link_screenshot_changed, …}`
  on the link owner's activity topic, `Vutuv.Organizations.Screenshots.announce/1`
  goes through `Organizations.broadcast_screenshot_changed/1` onto the page's —
  and `Vutuv.Moderation.ImageSubjects` calls those rather than keeping a second
  copy of who to tell. One event per kind for all three moments: a capture
  landing, a release and a refusal are one sentence to a reader, *re-read what
  you draw*. The `/:slug/links` index is a dead controller page and is
  deliberately left out.

Where it exists: post photos (`post_images/<token>/pixelated.avif`, served by
the proxy at `pixelated.avif` — which redirects to the real picture once
released, so a page rendered before the verdict never draws a broken image),
link screenshots and organization homepage captures
(`screenshots/<id>/pixelated-<hash>.avif`, in the *served* tree
while the thumb itself waits in quarantine) and pictures cached from other
networks (`remote_media/posts/<id>/pixelated-<hash>.avif` — the fingerprinted
name shape, for the two kinds whose directory outlives the picture in it). Not
avatars and covers, whose initials tile is the better placeholder at 36 pixels,
and not organization or job-posting images, which no page shows to a stranger
while they wait. The response is `ImageProxy.serve_pixelated/2`, the deliberate
counter-rule to that module's immutable cache header: never X-Accel'd, always
`no-store`, since the real picture takes the URL within seconds.

**The two drifts, and why the second one hurt (issue #1443).** Approval is two
writes in one order: `apply_approved/1` flips the row with `update_all`, then
promotes the files. A release that dies in between — or an `update_all` that
matches nothing and answers `:stale` — leaves the subject **no longer pending
with its bytes still in quarantine**, and `repair_drift/0` is blind to it,
because that query looks for rows that ARE pending. On production one profile
link sat like that for ten hours showing a broken image, and it came back only
because a deploy's `Vutuv.Uploads.Regenerator` rebuilt the thumb from the kept
original by accident. Two defences now: `Vutuv.Screenshot.url/2` **fails
closed** (a row naming a file that is not on disk renders the placeholder, not
a URL that 404s — and `<.link_thumb>` reads its `shot`/`pending` state off that
resolved src rather than off the column), and the hourly repair runs
`settle_stranded_quarantine/0`, which walks the quarantine tree (the stuck
state itself, where a query would have to test every row on disk to infer it)
and promotes a directory whose subject left `pending` and still names that
capture. It is fail-closed both ways: a subject still `pending` is left
strictly alone, and bytes no row claims — or whose row now names a different
capture — are deleted rather than published.

**Fail-closed by construction.** The gallery tables default `moderation` to
`pending` (an upload path that forgot to enqueue leaves the image invisible,
never leaked), display chokepoints treat only `nil`/`"approved"` as released
(`nil` = grandfathered pre-feature rows), re-uploads reset the open scan row
(partial unique index) and every verdict application is fingerprint-guarded,
so a stale verdict can never release bytes the model never saw. Remote
imagery (Mastodon/Bluesky account avatars on the profile social card) runs
through `Ollama.moderate_binary/1` before entering the feed cache — unsafe or
unjudgeable means the initials fallback.

**One unsafe answer does not delete anything.** The model's verdict on a
borderline but harmless picture (a cartoon skull, a horror-film still, a joke
image of frightened people) flips between runs even at temperature 0, so a
suspicion is put to a vote: the first opinion is the deterministic one and
decides alone when it comes back safe (so the ordinary upload still costs one
inference), while "unsafe" buys `:image_scan_votes` opinions in total,
sampled at a real temperature so they are independent draws rather than the
same answer again. The image is deleted only if `:image_scan_reject_votes` of
them agree — unanimous out of three by default, in dubio pro reo: deleting a
member's picture on a coin flip is the worse error, and a released image is
still reportable by every reader. A cleared suspicion is logged with the
model's own sentence (the log line to read when tuning the prompt); a service
failure mid-vote aborts the ballot, so nothing is decided on half a count.
The prompt itself is calibrated for this: fiction, comics, monsters, skulls,
horror motifs, memes and exaggerated fear are named as safe, "shocking" is
narrowed to real distressing imagery, and style ("dark", "in bad taste") is
explicitly not a reason to reject.

**Reading back what the scanner did.** Every line the queue writes is tagged
`image_scan`, so `journalctl -u vutuv | grep image_scan` is the whole feed and
`grep "image_scan rejected"` the deletions. One line per decided image carries
owner, kind, model, category, how the ballot fell and what each voice said:

```
image_scan rejected kind=avatar subject=<uuid> owner=<uuid> model=qwen3-vl:8b
  category=gore votes=3/3_unsafe reason="a bloodied arm"
  ballot=[gore: a bloodied arm | gore: blood on a wound | violence: someone hurt]
```

An outvoted suspicion logs the same shape as `image_scan cleared` (info); an
ordinary safe upload logs nothing, or the feed would be one line per upload.
Production's global level is `:error`, so `Vutuv.Application` raises
`Vutuv.Moderation.ImageScans` to `:info` at boot alongside the deliverability
alarms (`ops_log_visibility`) — without that the whole feed is silent there.

Logs rotate, the row does not: rejections **and** cleared suspicions keep the
ballot in `image_scans.votes`, readable per
`Vutuv.Moderation.ImageScans.recent_verdicts/1` or, on a release,

    bin/vutuv eval "Vutuv.Release.image_scan_verdicts()"

which prints each verdict with the model's description and every opinion. The
cleared ones are the more useful half for calibrating the prompt: unlike a
rejection, the image they concern is still there to look at.

Config: `:moderate_images` / `:ollama_url` / `:ollama_vision_model` /
`:image_scan_votes` / `:image_scan_reject_votes` (`IMAGE_MODERATION_ENABLED`,
`OLLAMA_URL`, `OLLAMA_VISION_MODEL` in `config/runtime.exs`; the two vote
knobs are `config/config.exs` flags). Off = images release immediately
(tests, installations without Ollama); both vote knobs at 1 = the old
single-opinion behaviour. `mix vutuv.moderation.backfill` queues the
grandfathered catalog through the same pipeline without hiding anything while
it waits.

`:ollama_url` may be a comma-separated list of instances, and `Vutuv.Ollama`
reads it two ways at once.

For **one call** it is a priority list: every instance but the last is tried
with `:ollama_remote_timeout` (30 s — enough for a GPU box to cold-load the
model) and skipped on any service failure; the last is the fallback of record
with the patient `:ollama_timeout` (120 s, covers a CPU cold load). Only
service-class failures fall through — a verdict is final wherever it came
from. vutuv.de runs
`http://bremen3.wintermeyer.de:11434,http://localhost:11434`: the GPU box
answers in seconds, the local CPU instance keeps moderation alive when it is
down.

For **overlapping calls** it is also a pool (issue #1573): a call made while
another is still running starts on the instance with the fewest requests
outstanding, ties going to the earlier entry — so one call at a time is
exactly the priority list above, while a second GPU box named in the list
takes work instead of only standing by for the first one to fail. The patient
budget stays with the last *configured* entry wherever the rotation puts it;
it is the instance an operator nominated as the one not to give up on.

The pool is `Vutuv.Ollama.concurrency/0` entries deep, from the head of the
list, and by default that is every entry **but the last**. The last one is the
fallback of record — on vutuv.de the web server's own CPU Ollama — and giving
it a share of the work would be a regression, not a feature. So the two-entry
production list above behaves exactly as it did; adding a second GPU box in
front of `localhost` is all it takes to use one. `:ollama_concurrency`
(`OLLAMA_CONCURRENCY`) overrides the depth, and is also the bound on how many
calls a background sweep runs at once.
