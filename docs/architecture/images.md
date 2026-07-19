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

## AI image moderation (the Ollama scan)

**Every** image that could become visible to anyone but its owner passes
through one gate before release: member uploads (avatar, cover, post /
job-posting / organization images) **and** the machine-generated link
screenshots (a screenshot of an NSFW page must not bypass the upload gate).
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
  in the image. Two error classes: `{:service, _}` (Ollama down — retry
  forever, fail-closed) vs `{:image, _}` (this file can't be judged — capped,
  then rejected; an unverifiable image is never released).
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

Config: `:moderate_images` / `:ollama_url` / `:ollama_vision_model`
(`IMAGE_MODERATION_ENABLED`, `OLLAMA_URL`, `OLLAMA_VISION_MODEL` in
`config/runtime.exs`). Off = images release immediately (tests, installations
without Ollama). `mix vutuv.moderation.backfill` queues the grandfathered
catalog through the same pipeline without hiding anything while it waits.

`:ollama_url` may be a comma-separated **priority list** of instances: every
instance but the last is tried with `:ollama_remote_timeout` (30 s — enough
for a GPU box to cold-load the model) and skipped on any service failure;
the last is the fallback of record with the patient `:ollama_timeout`
(120 s, covers a CPU cold load). Only service-class failures fall through —
a verdict is final wherever it came from. vutuv.de runs
`http://bremen3.wintermeyer.de:11434,http://localhost:11434`: the GPU box
answers in seconds, the local CPU instance keeps moderation alive when it is
down.
