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

The fingerprint is stored in `users.avatar_fingerprint` / `cover_fingerprint`; a
username change re-derives the files under the new handle. A row with no
fingerprint has not been migrated yet and serves the legacy
`avatar_<version>.avif?v=...` URL unchanged.

The migration is **expand/contract**: the regenerator writes the new files and
**keeps** the legacy ones (so the previous release and a rollback keep serving
them); once the scheme is confirmed healthy in production, `mix
vutuv.images.sweep_legacy` (`Vutuv.Release.sweep_legacy_images()`) deletes the
legacy files — a deliberate, manual step, never part of the deploy

## URL screenshots

URL screenshots are rendered by local headless Chromium, wrapped in a browser
window frame (`Vutuv.BrowserFrame`); see `Vutuv.PageScreenshot`. Needs a
`chromium`/`chrome` binary on the host (set `CHROMIUM_PATH` if it is not on
`$PATH`)

Three surfaces ask for one, all storing through `Vutuv.Screenshot` and gated by
`:generate_screenshots`: a member's **profile link** (`urls.screenshot`, captured
on save), a **post's single link** (`post_screenshots`, a durable queue, see
[posts-and-feed.md](posts-and-feed.md)) and an **organization's homepage**
(`organization_screenshots`, the same queue shape, see
[organizations.md](organizations.md)). They differ in one preflight: the link and
homepage paths **follow** redirects to their destination
(`PageScreenshot.capture_resolved/2`, every hop SSRF-vetted), because an apex
redirecting to `www.` is the normal shape of a homepage; the post path insists on
a plain HTTP 200 (`Vutuv.Posts.Screenshots.ensure_http_ok/1`), because there a
redirect usually means a shortener or a login wall.

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
