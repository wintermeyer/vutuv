# The vutuv teaser

A film of about 45 seconds, silent, recorded from a local dev server. It shows
three chapters, each on a colour of its own: Miriam Kessler's profile, the
feed, the job board. A fictional Elixir developer from Koblenz carries it.
The same pipeline makes it in German and English, and in two formats: 16:9 for
the desktop and 9:16 for the phone, the phone one recorded on a real phone
layout.

```sh
scripts/teaser/all.sh                   # both languages, then web.sh (about an hour)
scripts/teaser/run.sh de                # -> _build/teaser/de/vutuv-teaser-de.mp4 and portrait/…-portrait.mp4
scripts/teaser/run.sh de --portrait     # only the phone format
scripts/teaser/run.sh de --no-record    # cut again from the existing takes
scripts/teaser/web.sh                   # the start page's copies, see below
```

One language takes about 25 minutes: one take per format, then the cut.

The start page plays smaller copies, each AV1 with an H.264 fallback: the
desktop 960×540 (the full 1920×1080 behind an HD toggle), a phone the portrait
cut at 720×1280, full screen. Both show the same poster, the desktop cut's last
frame. `scripts/teaser/web.sh` makes them in `priv/static/images/teaser/`.

## Storyboard

A diagonal wipe brings each chapter's colour in with its word in big type; the
word shrinks into a label while the app rises in a floating window (a browser
window on the desktop, a phone on the phone). The recordings run in
fast-forward between their highlights and at real speed on them, and on the
desktop the camera pushes in on each highlight.

| Chapter | Scene | What happens |
|---|---|---|
| Profile | `profile` | Her profile as Anna sees it builds itself; the finished top stands a moment. Anna gives the tag "Elixir" her vote (2 → 3, the endorsers pop up), then on down through the CV to her book reviews (BookWyrm) and her links with their site screenshots. |
| Feed | `feed` | Miriam likes and reposts the top news item, writes her post (in jump cuts), bolds the second line, adds two tags, posts. |
| | drawn (`fediverse.py`) | The post flies out to servers across the world. |
| | `post` | Her post page: three likes pop in, Anna replies. Then ⋯ → "Reach analysis". |
| | `reach` | The reach analysis of an older post: the reposters' audiences grow as bars. |
| Jobs | `jobs` | The job board opens on postings that have nothing to do with Elixir; "Elixir" in Koblenz swaps the list for the jobs there. |
| End | `outro` | The three chapters as phones under the logo. |

The cut lives in `STORY` at the end of `render.py`: per scene, stretches of the
recording with their speed (a gap is a jump cut), and where the camera pushes
in. The times are seconds into each scene's clip, measured on the recordings,
so re-measure them when a scene's choreography changes. `PACE` slows the whole
film at once, `MOVE` sets how long a camera push takes.

## Changing something

| You want to change | Edit | Then run |
|---|---|---|
| Any text: post, reply, chapter titles, CV, jobs, links, book reviews, social posts, fake websites | `content.<lang>.json` | `run.sh <lang>` |
| Which news items head the feed | `news` in `content.<lang>.json` (text snippets of posts in the DB copy, plus the accounts Miriam follows) | `run.sh <lang>` |
| Speed, order, jump cuts, camera | `STORY`, `PACE`, `MOVE` in `render.py` | `run.sh <lang> --no-record` |
| One scene's choreography | its block in `record.mjs` (phone: `record_portrait.mjs`) | `run.sh <lang>`, then re-measure its times in `STORY` |
| Faces | the Unsplash URLs in `assets.py`; delete the file in `_build/teaser/assets/` | `run.sh <lang>` |
| The fediverse map | `fediverse.py` | `run.sh <lang> --no-record` |

## How it works

1. **`assets.py`** downloads the portraits of Miriam, Anna, Jonas and Lena
   and the Koblenz cover (Unsplash License), the world map (Natural Earth,
   public domain) and the network glyphs (Simple Icons, CC0; Friendica's own
   logo) into `_build/teaser/assets/`. Files already there are kept, so later
   runs are offline.
2. **`render_assets.mjs <lang>`** renders the white logo, the round network
   badges, the three fictional websites behind Miriam's links and the covers of
   her (fictional) books, in that language.
3. Then **one take per format**: `seed.exs`, `server.exs`, `login.mjs`, the
   recorder. Every take starts from a fresh seed, because recording changes the
   state (Anna's vote, the like and repost), and all scenes of a format come
   from the same take, so her post shows one time of day throughout the film.
   - **`seed.exs <lang>`** builds the situation in the local dev database,
     idempotently: the members Miriam, Anna, Jonas and Lena (all
     `@example.com`); Miriam's profile, CV, tags with their first
     endorsements, links, social and BookWyrm accounts and a GitHub snapshot;
     her post with three likes and Anna's reply; an older post with 56
     reactions from 15 invented servers for the reach analysis; 17 fictional
     job postings. It dates two real news posts of the database copy to
     "20 minutes ago" so they head her feed, and writes the ids the recorders
     need to `_build/teaser/<lang>/ids.json`.
   - **`server.exs <lang>`** starts the app on port 4077 with every outbound
     channel cut (see Safety) and Miriam's Mastodon, Bluesky and BookWyrm
     previews put into the social-feed cache.
   - **`login.mjs`** logs Miriam and Anna in through the real PIN flow.
   - **`record.mjs`** (1280×720, recorded at 1920×1080) or
     **`record_portrait.mjs`** (a 390×693 phone, recorded at 1080×1920)
     drives Chrome with Playwright and records each scene with the DevTools
     screencast. Pages "build themselves" because the recorder hides their
     parts and fades them in with CSS; the pointer is drawn and moved by real
     mouse events. Clicks that would navigate away are shown but not
     performed; the edit cuts instead.
4. **`render.py <lang> [--portrait]`** turns each recording into a 30 fps
   clip, cuts the chapters, draws the wipes, the fediverse map and the end,
   and exports `vutuv-teaser-<lang>.mp4` (H.264) plus the poster.

## Prerequisites

A worktree set up for a smoke test (see the project `CLAUDE.md`): `mix
deps.get`, a migrated dev database that is a copy of production, built assets
(`mix assets.setup && mix assets.build`), and the upload trees linked to the
shared image store. Plus Google Chrome, `ffmpeg`, `avifenc`, Node, and Python 3
with Pillow. If `mix assets.build` dies with exit 137, re-sign the Tailwind
binary: `codesign --force --sign - _build/tailwind-macos-arm64`.

The news items must exist in the database copy. If `seed.exs` stops with
"no news post containing …", pick another post and put a snippet of its text
into `content.<lang>.json` (`seed.exs` names the problem and the file). Prefer
posts with a link preview over posts with attached media: the copy usually
lacks the media files, and the post then shows a broken image.

## Safety

The dev database is a copy of production, with real members, real fediverse
followers and real push subscriptions. Nothing the teaser does may reach them:

* `seed.exs` runs with fediverse delivery, web push, screenshot capture and
  image moderation switched off. The invented remote accounts behind the reach
  analysis carry follower counts stamped as just checked, so no refresh ever
  asks their servers, which do not exist.
* `server.exs` keeps the fediverse on (the like and repost buttons on remote
  posts need it) but answers **every** outbound ActivityPub request with a
  local stub. `run.sh` prints how many requests the stub caught.
* All people shown acting are fictional. Real accounts still appear at the
  edges: the two news posts and the feed items further down. Check them before
  publishing a new cut.
* The job postings, companies, books, websites, servers and social accounts
  are invented. Do not reuse the domains without checking they do not exist.
