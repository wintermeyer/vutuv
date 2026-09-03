# Video on posts

A post can carry one clip (issue #1906): up to two minutes and 500 MB by
default, both per installation. This document is the pipeline behind it, from
the composer's upload to the four files a page offers, and the three surfaces
that show it on the way.

Photos are in [images.md](images.md); this page only covers what a clip does
differently.

## Off switch

`Vutuv.Videos.enabled?/0` is the product flag (`VIDEO_UPLOADS`, default on)
**and** the presence of `ffmpeg` and `ffprobe` on the machine, probed once per
boot. An installation without the binaries — an air-gapped intranet, a
container built without them — simply has no video: the composer offers no
picker, the Mastodon API announces no video limits, and nothing else changes.

## Who may upload

`Vutuv.Videos.uploads_for?/1` answers per member: an admin always (while
`enabled?/0` holds), anyone else once the installation sets
`VIDEO_UPLOADERS=members` (`:uploaders` in `:post_videos`, default
`:admins`). `create_pending_video/3` is the chokepoint; the surfaces only
hide, and a member outside the audience gets the picture-only refusal from
both APIs rather than a hint that video exists. `advertised?/0` is the
anonymous half: the Mastodon instance answer names video only once every
member may upload, because a client shows its video button to whoever reads
it — so while uploads are for admins, even they cannot reach video from a
Mastodon client. Playback is never gated.

## The upload

The composer uploads a clip over the LiveView socket like a photo, eagerly:
`Vutuv.Videos.create_pending_video/3` refuses a file over the size cap before
reading it, keeps the original in the private `originals/post_videos/<token>/`
tree, probes it with `ffprobe` (a clip over the length cap is refused here,
after the upload), inserts a `Vutuv.Posts.PostVideo` row with no post yet, and
nudges the pipeline. The original leaves the server on **no path** — unlike a
photo there is no download switch — and is kept so a later codec change can
re-derive every rendition from the upload rather than from a rendition.

## The pipeline

`Vutuv.Videos.Pipeline` runs `Vutuv.Videos.Job` for at most `VIDEO_CONCURRENCY`
clips at once (two), each step stamped on the row when it is done:

1. **frames** — the opening frame, one every twenty seconds and one at every
   hard cut (scene detection on a 320-pixel copy, at most 24 stills), written
   as JPEGs beside the original. The most representative frame of the opening
   seconds (ffmpeg's `thumbnail` filter) becomes the default cover; the
   author picks another from the strip in the composer.
2. **the AI check** — every still is queued through the same
   `Vutuv.Moderation.ImageScans` a photo goes through, as its own subject
   (`post_video_frame`). One refused frame refuses the whole clip, deletes
   every file of it and tells the member the second it happened at; a scan
   that cannot run holds the clip rather than releasing it.
3. **H.264** — 720p (the shorter side capped), High profile, `crf 23`,
   `maxrate 2500k`, AAC 128k. The profile Mastodon copies without
   re-encoding, so it is the one file that federates, and the fallback every
   browser plays. Its progress is what the author watches.
4. **AV1** — 1080p, SVT-AV1 preset 8, `crf 35`: about half the bytes at the
   same quality, offered first to browsers that decode it. Skipped where
   ffmpeg has no `libsvtav1`.
5. **the 360p pair** — an AV1 and an H.264 file with 48 kbit/s mono AAC for
   data-saving mode (issue #1924): together under two megabytes for a
   two-minute talk against 37 for the 720p file.

A clip is **ready** once the H.264 file exists and the check has passed; the
rest are enhancements, and a page offers what is on disk
(`Vutuv.Posts.PostVideo.sources/1`). Every rendition is written to a temporary
name and renamed on success, and every `ffmpeg` run is `nice`d and capped in
threads (`VIDEO_THREADS`).

**A job a deploy kills is resumed, from the step it lost.** The claim is a
compare-and-set on the row's `worked_at` heartbeat, refreshed on every progress
tick; a row nobody has touched for three minutes is claimed again on the next
poll, the job reads the stamps, sweeps the temporary file and carries on. The
two slots of a blue/green deploy can overlap without working the same clip
twice. `Vutuv.VideosTest` kills a job mid-encode and asserts the resume.

## The post waits, not the picture

A photo post publishes at once and its picture catches up; a text whose video
is missing reads as broken. So a post with a clip is not created until the
clip is ready: the composer's submission is stored as a
`Vutuv.Posts.PendingVideoPost` — the create path it took, the context that path
needs and the attrs verbatim — and `Vutuv.Videos.Publisher` turns the row into
the post through the very `Vutuv.Posts.create_*` function the composer would
have called, the moment the clip is ready. A post with a clip that is already
ready posts on the spot. No feed or profile query needs a new filter, because
there is no post to filter.

A refused or broken clip keeps the text: the row waits with the verdict on it,
and the author's feed card offers to publish without the video or to drop it.

## What the author sees

Every change of state is broadcast on the author's video topic
(`Vutuv.Videos.subscribe/1`, `"post_video:<user_id>"`), and three surfaces
draw from it:

* the **composer's tile** — cover, length, the stage line ("Converting ·
  62 %", "Our AI is checking it, 4 of 6 frames done") and the strip of stills
  to pick the cover from. A LiveComponent cannot subscribe itself, so
  `VutuvWeb.Live.VideoProgress` subscribes once per host page (an `on_mount`
  on the routed reply pages, `attach/2` from the embedded feed's and
  organization page's mount) and forwards each `{:post_video, …}` to the
  composer that registered the clip. A percent is patched in place; a stage,
  a verdict or a cover change re-reads the row.
* the **waiting card** above the feed's timeline (`VutuvWeb.VideoComponents.
  pending_video_post/1`): the text, the tile, the stage, the length rounded
  up to whole minutes, a cancel button, and after a refusal the two ways out.
* the **chip in the app bar** (`VutuvWeb.ShellLive`), on every page: how
  many posts wait on a clip and the percent of the one being converted,
  linking to the feed.

## The player and the proxy

`VutuvWeb.VideoComponents.post_video/1` renders the native player — no
autoplay, `preload="none"`, the cover as the poster with a play glyph and the
length over it — with `<source>` elements best first: AV1 with a `codecs`
string, so a browser without an AV1 decoder skips it, then H.264. A viewer in
data-saving mode (`Vutuv.LowBandwidth`) gets the two 360p files first and an
**HD** control that reloads the player with the full files where it was.

Every byte goes through `VutuvWeb.PostVideoController` at
`/post_videos/:token/:file`, which asks the post's audience the way the image
proxy does and **answers byte ranges itself** (206, `Content-Range`,
`Accept-Ranges`): Safari opens a clip with `Range: bytes=0-1` and refuses to
play from a server that answers 200. Only the renditions, the two covers, the
cover as JPEG for link scrapers (`cover.jpg`) and the author-only stills
(`frame-NN.jpg`, never cached) resolve.

## Elsewhere

* **Fediverse, out** (issue #1913): the Note carries one `Document` of type
  `video/mp4` naming the H.264 file, with `name`, `width`, `height`,
  `duration` (ISO 8601) and an `icon` with the cover as JPEG. Photo
  attachments gained `name` and their size at the same time.
* **Fediverse, in** (issue #1914): a video attachment on a post from another
  network is recorded in `fediverse_post_images` with its `media_type` and its
  cover's `poster_uri`; only the cover is fetched and judged, the clip plays
  straight from its server (`preload="none"`, up to 99 MB a post on
  Mastodon). A clip with no cover is playable as it is and never enters the
  refetch queue.
* **Mastodon API** (issue #1915): `POST /api/v1|v2/media` takes a clip and
  answers 202, `GET /api/v1/media/:id` 206 until it is ready, a status naming
  an unfinished clip is refused with 422 and Mastodon's own sentence, the
  attachment is described as `video`, and `/api/v2/instance` announces the
  real limits. The endpoint's multipart limit is 520 MB; nginx's
  `client_max_body_size` in front has to match ([ADMINS.md](../ADMINS.md)).
* **`/api/2.0`**: `POST /me/post_videos` (202), `GET /me/post_videos/:id`,
  `DELETE`, and `video_id` on `POST /posts`.
* **Agent formats**, `og:image`, the JSON API: the clip's H.264 URL, cover,
  length and description ride the post document; a post with a clip and no
  photo previews with the cover.

## Housekeeping

Unattached clips older than a day are swept unless a draft or a waiting post
names them (`Vutuv.Videos.sweep_pending_videos/0`, run by
`Vutuv.Posts.PendingImageSweeper` beside the images). Deleting a post or an
account deletes the clip's files with it.
