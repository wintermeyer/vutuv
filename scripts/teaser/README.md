# The vutuv teaser

A 108-second film, silent and without captions, recorded from a local dev
server. It follows Miriam Kessler, a fictional Elixir developer from Koblenz,
from her morning feed to a job offer and a CV saved as PDF. The same pipeline
makes it in German and English, and in two formats: 16:9 for the desktop and
9:16 for the phone, the phone one recorded on a real phone layout.

```sh
scripts/teaser/all.sh                 # everything below, then web.sh (about an hour)
scripts/teaser/run.sh de              # -> _build/teaser/de/vutuv-teaser-de.mp4 (+ -poster.png)
scripts/teaser/run.sh de --portrait   # -> _build/teaser/de/portrait/vutuv-teaser-de-portrait.mp4
scripts/teaser/run.sh en              # the same in English
scripts/teaser/run.sh en --portrait
scripts/teaser/web.sh                 # the start page's copies, see below
```

One run takes about 15 minutes: roughly 3 recording and 10 rendering.

The start page plays smaller copies, each AV1 with an H.264 fallback: the
desktop 960×540 (the full 1920×1080 behind an HD toggle), a phone the portrait
cut at 720×1280, full screen. Both show the same poster, the desktop one.
`scripts/teaser/web.sh` makes them in `priv/static/images/teaser/`.

## Storyboard

| # | Time | Shot | What happens | Recorder scene |
|---|------|------|--------------|----------------|
| 0 | 0:00 | Phones | Three light phone screens slide in: Miriam's profile, her feed, her CV. Something moves from the first frame; after half a second the outer two leave and the middle one grows into the desktop feed. The poster is the frame at 0.9 s. | `phones` |
| 1 | 0:03 | Feed | The feed builds itself. Miriam likes and reposts the top news item, opens the composer, types two lines, selects the second line with the mouse, clicks **B**, adds three tags, clicks "Post". The composer folds away and her post lands on top. | `feed` |
| 2 | 0:22 | Fediverse | The post shrinks into a dot over Koblenz; arcs fly to 15 servers worldwide, each pops a network badge. | drawn (`fediverse.py`) |
| 3 | 0:27 | Resonance | Her post page: three likes pop in, Anna's reply arrives, the bell counts up, then the envelope gets a badge and the pointer clicks it. | `post` |
| 4 | 0:36 | DM | "Anna is typing…", then Anna's message: a link to the job, "have a look at the job board", "send me your CV as a PDF by email. **But without a photo!**". Miriam answers and clicks the link. | `chat` |
| 5 | 0:52 | Posting | The job posting builds itself and scrolls through its long description to the tags; back up, click "Jobs". | `job` |
| 6 | 1:01 | Job board | Search "Elixir", city "Koblenz", radius 50 km: the list narrows to the Koblenz area. Then "Profile". | `jobs` |
| 7 | 1:15 | Her profile | Her own profile builds itself in full: header, contact, profiles, GitHub card, social posts, tags, CV, education, languages, links. Then "Open CV". | `owner` |
| 8 | 1:29 | CV | Untick "Photo" (it greys out), click "Print / Save as PDF". | `cv` |
| 9 | 1:36 | Print view | The printed CV, without photo, builds itself line by line. | `print` |
| 10 | 1:40 | Saved | The sheet lifts off, becomes a PDF file (`pdf_name`), drops into a download folder, a green check. | drawn (`savepdf.py`), uses `sheet` |
| 11 | 1:45 | Logo | The white vutuv logo on blue. | drawn |

The cut order and each shot's speed live in `SHOTS` at the end of
`render.py`. A shot plays a stretch of its recording faster than real time
(`speed(feed, 1.25)` = 25 % faster); change the factor to lengthen or shorten
it.

### The phone cut

Same story, same texts, same order. `record_portrait.mjs` plays it on a
390×693 phone screen (recorded at 1080×1920) with a fingertip instead of a
pointer, and takes the phone's own way where the navigation differs: writing
starts from the tab bar's "Write" button, the envelope and the bell light up
in the tab bar, "Jobs" is in the footer, "Profile" sits in the avatar's menu,
and the one-column profile scrolls from the header down to the CV card.
`render.py --portrait` cuts it with the same shots; the phones, the map and
the save animation are drawn for the tall frame.

## Changing something

| You want to change | Edit | Then run |
|---|---|---|
| Any text: post, reply, DM, CV, jobs, links, social posts, fake websites, PDF name | `content.<lang>.json` | `run.sh <lang>` |
| Which news items head the feed | `news` in `content.<lang>.json` (text snippets of posts in the DB copy, plus the accounts Miriam follows) | `run.sh <lang>` |
| Speed or order of shots | `SHOTS` in `render.py` | `python3 scripts/teaser/render.py <lang> [--portrait]` (no re-recording) |
| One scene's choreography | its block in `record.mjs` (phone: `record_portrait.mjs`) | `run.sh <lang> [--portrait] <scene>` (seeds again, records only that scene, renders) |
| Miriam's photos | the two Unsplash URLs in `assets.py`; delete `_build/teaser/assets/raw_*.jpg` | `run.sh <lang>` |
| The fediverse map or the save animation | `fediverse.py`, `savepdf.py` | `render.py <lang>` |

Always re-seed before re-recording (`run.sh` does): the chat scene sends real
messages and the feed scene likes a news post, so a second take on an
unseeded database starts from the wrong state.

## How it works

1. **`assets.py`** downloads Miriam's portrait and the Koblenz cover
   (Unsplash License), the world map (Natural Earth, public domain) and the
   network glyphs (Simple Icons, CC0; Friendica's own logo) into
   `_build/teaser/assets/`, then crops the photos. Files already there are
   kept, so later runs are offline.
2. **`render_assets.mjs <lang>`** renders the white logo, the round network
   badges, and the three fictional websites behind Miriam's links, in that
   language.
3. **`seed.exs <lang>`** builds the whole situation in the local dev
   database, idempotently: the members Miriam Kessler, Anna Berger, Jonas
   Keller and Lena Hoffmann (all `@example.com`); Miriam's profile, CV, links
   with the rendered screenshots, social accounts and a GitHub snapshot; her
   post with three likes and Anna's reply; a clean chat with two opening
   messages; 13 fictional Elixir job postings. It dates two real news posts of
   the database copy to "20 minutes ago" so they head her feed, and writes the
   ids the recorder needs to `_build/teaser/<lang>/ids.json`.
4. **`server.exs <lang>`** starts the app on port 4077 with every outbound
   channel cut (see Safety) and Miriam's Mastodon/Bluesky previews put into
   the social-feed cache.
5. **`login.mjs`** logs Miriam and Anna in through the real PIN flow, reading
   the PIN from the dev mailbox.
6. **`record.mjs <lang> [scene …]`** drives Chrome (Playwright) scene by
   scene and records each with the Chrome DevTools screencast. Pages "build
   themselves" because the recorder hides their parts and fades them in with
   CSS; the pointer is a drawn cursor moved by real mouse events. Chrome is
   launched with `--force-device-scale-factor`: without it, headless Chrome
   hands the screencast over in CSS pixels (1280×720, or 390 wide on the
   phone), and the film comes out soft. Clicks that
   would navigate away are shown but not performed; the edit cuts instead.
7. **`render.py <lang>`** turns each recording into a 30 fps clip, cuts them
   with cross-fades, draws the phone morph, the fediverse map, the save-as-PDF
   animation and the logo, and exports `vutuv-teaser-<lang>.mp4` (H.264,
   1920×1080, CRF 24) plus the poster.

## Prerequisites

A worktree set up for a smoke test (see the project `CLAUDE.md`): `mix
deps.get`, a migrated dev database that is a copy of production, built assets
(`mix assets.setup && mix assets.build`), and the upload trees linked to the
shared image store. Plus Google Chrome, `ffmpeg`, Node, and Python 3 with
Pillow. If `mix assets.build` dies with exit 137, re-sign the Tailwind binary:
`codesign --force --sign - _build/tailwind-macos-arm64`.

The news items must exist in the database copy. If `seed.exs` stops with
"no news post containing …", pick another post and put a snippet of its text
into `content.<lang>.json` (`seed.exs` names the problem and the file). Prefer
posts with a link preview over posts with attached media: the copy usually
lacks the media files, and the post then shows a broken image.

## Safety

The dev database is a copy of production, with real members, real fediverse
followers and real push subscriptions. Nothing the teaser does may reach them:

* `seed.exs` runs with fediverse delivery, web push, screenshot capture and
  image moderation switched off.
* `server.exs` keeps the fediverse on (the like/repost buttons on remote posts
  need it) but answers **every** outbound ActivityPub request with a local
  stub. `run.sh` prints how many requests the stub caught.
* All people shown acting are fictional. Real accounts still appear at the
  edges: the two news posts, the feed items further down, and the "new here"
  rail. Check them before publishing a new cut.
* The job postings, companies, websites and social accounts are invented. Do
  not reuse the domains without checking they do not exist.
