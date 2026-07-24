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

Every uploaded **original** is kept verbatim (format + metadata) under the
private `<UPLOADS_DIR_PREFIX>/originals/` tree (`Vutuv.Uploads.Originals`) as
the source for re-deriving — it must **never** be served (no `Plug.Static`
mount, no nginx alias; a regression test enforces this).

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

The capture browser sends vutuv's own `User-Agent`
(`Vutuv.SocialFeed.Http.user_agent/0`), the same string the HTTP preflight
probe uses, so a site sees one agent for both requests. It also lets our own
pages recognise a capture: `--screenshot` renders the document **from the
top**, so a page that scrolls itself on arrival is shot before those tiles are
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

The guard therefore constrains Chromium itself. `Vutuv.PageScreenshot.capture_framed/2`
resolves the target host **once** through `Vutuv.Ssrf.vetted_address/1`
(fail-closed: any resolved internal address refuses the whole capture) and pins
the browser to that exact IP with `--host-resolver-rules=MAP * <vetted-ip>`.
Chromium then does no DNS of its own, so every request it makes — the seed page,
its subresources, and any redirect / meta-refresh / in-page navigation — goes to
the one vetted public address. This also closes the check-vs-fetch (TOCTOU) DNS
rebinding window, since there is no second lookup to poison. The real hostname
still rides in `Host:`/SNI, so the intended page renders; only a *different*
host is pinned to the wrong address and simply fails to load — an accepted
fidelity trade for cross-host subresources.

`Vutuv.Moderation.EvidenceScreenshot` calls `capture/3` without a pin, on
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
the machine-fetched ones — link screenshots (a screenshot of an NSFW page
must not bypass the upload gate) and the book covers on post reviews
(`review_cover`, fetched from Open Library by ISBN). A PDF proof document is
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
  asset stranded in `pending`.

**Limbo.** A fresh image starts `pending`: the owner sees it (avatar/cover
through the authenticated `/settings/pending_image/...` quarantine preview,
gallery images through the authorizing proxies) with an amber "wird geprüft"
pill; everyone else gets a placeholder (initials tile / gradient / gallery
placecard). For the nginx-served kinds (avatars, covers, screenshots) the
derived files wait in `<UPLOADS_DIR_PREFIX>/quarantine/...`, a tree nginx has
no location for, so an unreleased byte is unreachable by URL no matter what a
template renders. Approval moves the files into the served tree; rejection
deletes served + quarantine + original (nothing unsafe stays at rest), clears
the asset's reference and notifies the owner (in-app + email, both derived
from the audit row). Organization logos differ deliberately: the
`organizations.logo` pointer only ever names a released image, so the old
logo keeps showing while the new one is scanned.

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

`:ollama_url` may be a comma-separated **priority list** of instances: every
instance but the last is tried with `:ollama_remote_timeout` (30 s — enough
for a GPU box to cold-load the model) and skipped on any service failure;
the last is the fallback of record with the patient `:ollama_timeout`
(120 s, covers a CPU cold load). Only service-class failures fall through —
a verdict is final wherever it came from. vutuv.de runs
`http://bremen3.wintermeyer.de:11434,http://localhost:11434`: the GPU box
answers in seconds, the local CPU instance keeps moderation alive when it is
down.
