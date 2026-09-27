"""Cuts the recorded scenes into the finished teaser.

    python3 scripts/teaser/render.py <lang>              # 1920x1080, the desktop cut
    python3 scripts/teaser/render.py <lang> --portrait   # 1080x1920, the phone cut

Reads  _build/teaser/<lang>/rec/<scene>/ (record.mjs) or portrait/rec/<scene>/
       (record_portrait.mjs), screens/ (the outro's phone shots) and
       _build/teaser/assets/ (assets.py, render_assets.mjs)
Writes _build/teaser/<lang>/master.mp4 (near-lossless), vutuv-teaser-<lang>.mp4
       and a poster PNG; the phone cut the same under portrait/, named
       vutuv-teaser-<lang>-portrait.*

The style: three chapters, each on a colour of its own. A diagonal wipe brings
the colour in with the chapter's word in big type; the word shrinks into a
label while the app rises in a floating window (a browser window on the
desktop, a phone on the phone). The recordings run in fast-forward between
their highlights and at real speed on them, and the camera pushes in on each
highlight. The end fans the three chapters out as phones under the logo.
The storyboard lives in STORY at the end; README.md explains each shot.
"""
import bisect
import functools
import json
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
from fediverse import Fediverse  # noqa: E402

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
PORTRAIT = "--portrait" in sys.argv
LANG = ARGS[0] if ARGS else "de"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BASE_OUT = os.path.join(ROOT, "_build", "teaser", LANG)
OUT = os.path.join(BASE_OUT, *(["portrait"] if PORTRAIT else []))
NAME = f"vutuv-teaser-{LANG}" + ("-portrait" if PORTRAIT else "")
ASSETS = os.path.join(ROOT, "_build", "teaser", "assets")
CONTENT = json.load(open(os.path.join(os.path.dirname(__file__), f"content.{LANG}.json")))
B = CONTENT["trailer_b"]
W, H, FPS = (1080, 1920, 30) if PORTRAIT else (1920, 1080, 30)

# every recording plays this much slower than its segment speeds say: one knob
# for the whole film's pace (1.0 read as hectic, 1.18 adds about five seconds)
PACE = 1.18
# how long the camera takes to push in or pull out, in film time; keyed to the
# recording, a push inside a fast-forward stretch shrank to a jolt
MOVE = 0.9

NAVY = ((11, 16, 36), (22, 30, 64))
COLOURS = [((29, 66, 180), (56, 110, 245)),    # Profile: vutuv blue
           ((232, 72, 85), (255, 138, 91)),    # Feed: coral
           ((8, 145, 140), (34, 197, 94))]     # Jobs: teal to green

# The layout of each format: the window the app plays in (content size, the
# browser bar above it, where it sits, its corner), the big title and the
# small label it shrinks into, the backdrop's outline word, the outro.
L = {
    False: dict(cw=1500, ch=844, bar=40, wx=210, wy=150, radius=18, rise=760,
                word=(140, 360, 210), line=(146, 610, 50), label=(80, 58, 40), logo=(150, 62),
                outline=(-30, H - 520, 560), wrap=1600,
                phone_h=900, fan=540, fan_y=700, outro_logo=(380, 64)),
    True: dict(cw=860, ch=1529, bar=0, wx=110, wy=300, radius=48, rise=1400,
               word=(90, 640, 170), line=(96, 860, 46), label=(70, 120, 40), logo=(150, 128),
               outline=(-20, H - 440, 400), wrap=880,
               phone_h=860, fan=340, fan_y=1200, outro_logo=(380, 330)),
}[PORTRAIT]
CW, CH, BAR, WX, WY, RADIUS = L["cw"], L["ch"], L["bar"], L["wx"], L["wy"], L["radius"]


# ---------------------------------------------------------------- basics
def ease(t):
    t = max(0.0, min(1.0, t))
    return 4 * t**3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ease_out(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def back_out(t, s=1.4):
    t = max(0.0, min(1.0, t)) - 1
    return t * t * ((s + 1) * t + s) + 1


def smooth(t):
    t = max(0.0, min(1.0, t))
    return 0.5 - 0.5 * math.cos(math.pi * t)


def lerp(a, b, t):
    return a + (b - a) * t


@functools.lru_cache(maxsize=None)
def font(size, bold=False):
    return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)


def gradient(a, b):
    g = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(g)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=tuple(int(lerp(a[i], b[i], y / H)) for i in range(3)))
    return g


def rounded(w, h, r):
    m = Image.new("L", (w * 2, h * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * 2 - 1, h * 2 - 1), r * 2, fill=255)
    return m.resize((w, h), Image.Resampling.LANCZOS)


@functools.lru_cache(maxsize=None)
def wrap(text, f, width):
    """The line broken into lines no wider than `width`."""
    lines, cur = [], ""
    for word in text.split():
        probe = f"{cur} {word}".strip()
        if cur and f.getlength(probe) > width:
            lines.append(cur)
            cur = word
        else:
            cur = probe
    return tuple(lines + [cur])


LOGO = Image.open(os.path.join(ASSETS, "logo_white_full.png"))
LOGO = LOGO.crop(LOGO.getbbox())


def logo(width):
    return LOGO.resize((width, int(LOGO.height * width / LOGO.width)), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------- recordings -> clips
def clip(scene):
    """Turns the screencast frames (irregular timestamps) into a constant 30 fps clip; cached."""
    src = os.path.join(OUT, "rec", scene)
    dst = os.path.join(OUT, "clips", f"{scene}.mp4")
    meta = json.load(open(os.path.join(src, "frames.json")))["frames"]
    if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(os.path.join(src, "frames.json")):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        ts = [t for _, t in meta]
        start, end = ts[0], ts[-1] + 0.5
        ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                               "-c:v", "libx264", "-preset", "fast", "-crf", "12", "-pix_fmt", "yuv420p", dst], stdin=subprocess.PIPE)
        last, buf = None, None
        for i in range(int((end - start) * FPS)):
            j = max(0, bisect.bisect_right(ts, start + i / FPS) - 1)
            if j != last:
                im = Image.open(meta[j][0]).convert("RGB")
                if im.size != (W, H):
                    im = im.resize((W, H), Image.Resampling.LANCZOS)
                buf, last = im.tobytes(), j
            ff.stdin.write(buf)
        ff.stdin.close()
        ff.wait()
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dst], capture_output=True, text=True).stdout
    return dst, float(out.strip())


def last_frame(path):
    b = subprocess.run(["ffmpeg", "-v", "error", "-sseof", "-0.1", "-i", path, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                       capture_output=True).stdout
    return Image.frombytes("RGB", (W, H), b[: W * H * 3])


class Src:
    """Streams a scene clip frame by frame, forward only."""

    def __init__(self, scene):
        self.path, self.dur = clip(scene)
        rec = os.path.join(OUT, "rec", scene)
        start = json.load(open(os.path.join(rec, "frames.json")))["frames"][0][1]
        marks = os.path.join(rec, "marks.json")
        # record()'s marks, as seconds into this clip
        self.marks = {k: v - start for k, v in json.load(open(marks)).items()} if os.path.exists(marks) else {}

    def open(self):
        self.p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", self.path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)  # closed early on purpose
        self.idx, self.cur = -1, None

    def at(self, t):
        want = max(0, int(round(t * FPS)))
        while self.idx < want:
            b = self.p.stdout.read(W * H * 3)
            if len(b) < W * H * 3:
                break
            self.cur, self.idx = Image.frombytes("RGB", (W, H), b), self.idx + 1
        return self.cur

    def close(self):
        self.p.stdout.close()
        self.p.wait()


class Fedi:
    """The fediverse map (fediverse.py), lifting the new post off the feed's last frame."""

    dur = 5.0

    def __init__(self, feed):
        geometry = {}
        if PORTRAIT:
            # the phone's post card (record_portrait.mjs) and a narrower world
            geometry = {"card": tuple(json.load(open(os.path.join(OUT, "screens", "card.json")))), "end_span": 300}
        self.map = Fediverse(last_frame(feed.path), ASSETS, duration=self.dur, size=(W, H), **geometry)

    def open(self):
        pass

    def at(self, t):
        return self.map(min(1.0, t / self.dur))

    def close(self):
        pass


# ---------------------------------------------------------------- the window
MASK = rounded(CW, CH + BAR, RADIUS)
SHADOW = Image.new("L", (CW + 160, CH + BAR + 160), 0)
ImageDraw.Draw(SHADOW).rounded_rectangle((80, 100, 80 + CW, 100 + CH + BAR), RADIUS, fill=120)
SHADOW = SHADOW.filter(ImageFilter.GaussianBlur(34))


def chrome(url):
    """The browser bar with the page's address; the phone has none."""
    if not BAR:
        return None
    bar = Image.new("RGB", (CW, BAR), (238, 241, 246))
    d = ImageDraw.Draw(bar)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse((18 + i * 22, 14, 30 + i * 22, 26), fill=c)
    f = font(17)
    tw = d.textlength(url, font=f)
    d.rounded_rectangle(((CW - tw) / 2 - 24, 7, (CW + tw) / 2 + 24, 33), 13, fill=(255, 255, 255))
    d.text(((CW - tw) / 2, 10), url, font=f, fill=(90, 100, 120))
    return bar


def window(content, bar):
    if bar is None:
        return content
    win = Image.new("RGB", (CW, CH + BAR))
    win.paste(bar, (0, 0))
    win.paste(content, (0, BAR))
    return win


def put_window(frame, win, dy=0):
    frame.paste((0, 0, 0), (WX - 80, WY - 80 + dy), SHADOW)
    frame.paste(win, (WX, WY + dy), MASK)


def view(frame, cx, cy, z):
    vw, vh = W / z, H / z
    x0 = min(max(0, cx - vw / 2), W - vw)
    y0 = min(max(0, cy - vh / 2), H - vh)
    return frame.resize((CW, CH), Image.Resampling.BILINEAR, box=(x0, y0, x0 + vw, y0 + vh))


# ---------------------------------------------------------------- titles and backdrops
def backdrop(colours, word=None):
    """The chapter's colour, with its word as a huge outline behind the window."""
    g = gradient(*colours).convert("RGBA")
    if word:
        x, y, size = L["outline"]
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(layer).text((x, y), word, font=font(size, bold=True), fill=(255, 255, 255, 0),
                                   stroke_width=3, stroke_fill=(255, 255, 255, 46))
        g.alpha_composite(layer)
    lw, ly = L["logo"]
    lg = logo(lw)
    g.alpha_composite(lg, (W - 80 - lg.width, ly))
    return g.convert("RGB")


def draw_line(layer, line, dy, alpha):
    x, y, size = L["line"]
    f = font(size)
    for i, part in enumerate(wrap(line, f, L["wrap"])):
        ImageDraw.Draw(layer).text((x, y + dy + i * size * 1.3), part, font=f, fill=(255, 255, 255, alpha))


def title(frame, word, line, k):
    """k = 0: the big title; k = 1: the small label top left."""
    (bx, by, bs), (sx, sy, ss) = L["word"], L["label"]
    ImageDraw.Draw(frame).text((lerp(bx, sx, k), lerp(by, sy, k)), word, font=font(int(lerp(bs, ss, k)), bold=True), fill="white")
    a = 1 - ease(k * 2.5)
    if a > 0:
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        draw_line(layer, line, 0, int(235 * a))
        base = frame.convert("RGBA")
        base.alpha_composite(layer)
        frame.paste(base.convert("RGB"))


class Wipe:
    """A diagonal band of the next colour sweeps over the last frame; its word lands."""

    def __init__(self, T, prev, bg, word=None, line=None):
        self.T, self.prev, self.bg, self.word, self.line = T, prev, bg, word, line

    def load(self, n):
        self.prev_im = self.prev()

    def __call__(self, u):
        t = u * self.T
        k = ease(t / 0.45)
        f = self.bg.copy()
        if self.word:
            rise = ease_out((t - 0.2) / 0.45)
            if rise > 0:
                x, y, size = L["word"]
                layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
                ImageDraw.Draw(layer).text((x, y + 70 * (1 - rise)), self.word, font=font(size, bold=True),
                                           fill=(255, 255, 255, int(255 * rise)))
                sub = ease_out((t - 0.4) / 0.4)
                if sub > 0:
                    draw_line(layer, self.line, 30 * (1 - sub), int(235 * sub))
                base = f.convert("RGBA")
                base.alpha_composite(layer)
                f = base.convert("RGB")
        if k >= 1:
            return f
        edge = lerp(-500, W + 500, k)
        m = Image.new("L", (W, H), 0)
        ImageDraw.Draw(m).polygon([(0, 0), (edge + 260, 0), (edge - 260, H), (0, H)], fill=255)
        out = self.prev_im.copy()
        out.paste(f, (0, 0), m)
        return out


# ---------------------------------------------------------------- recordings in the window
class Part:
    """A stretch of one source in the window.

    `segs` are (s0, s1, speed) stretches of the recording, played back to back
    (a gap between two is a jump cut). `holds` are (s0, s1, cx, cy, zoom): the
    camera sits pushed in on (cx, cy) while the recording is between s0 and s1,
    moving in before and out after over MOVE seconds of film time.
    """

    def __init__(self, src, url, segs, holds=()):
        self.src, self.bar = src, chrome(url)
        self.segs = [(s0, s1, sp / PACE) for s0, s1, sp in segs]
        self.T = sum((s1 - s0) / sp for s0, s1, sp in self.segs)
        self.holds = [(self.film_time(a), self.film_time(b), cx, cy, z) for a, b, cx, cy, z in holds]

    def film_time(self, st):
        """When the film shows source time st (the next segment's start if st was jumped)."""
        acc = 0.0
        for s0, s1, sp in self.segs:
            if st <= s1:
                return acc + max(0.0, st - s0) / sp
            acc += (s1 - s0) / sp
        return acc

    def cam(self, t):
        cx, cy, z = W / 2, H / 2, 1.0
        for a, b, hx, hy, hz in self.holds:
            k = min(smooth((t - (a - MOVE)) / MOVE), 1 - smooth((t - b) / MOVE))
            if k > 0:
                # the zoom in log space, so the push feels even from start to end
                cx, cy = lerp(cx, hx, k), lerp(cy, hy, k)
                z = math.exp(lerp(math.log(z), math.log(hz), k))
        return cx, cy, z

    def src_time(self, t):
        for s0, s1, sp in self.segs:
            d = (s1 - s0) / sp
            if t <= d:
                return s0 + t * sp
            t -= d
        return self.segs[-1][1]

    def content(self, t):
        return view(self.src.at(self.src_time(t)), *self.cam(t))


class Chapter:
    """The chapter's parts back to back in one window, which rises in at the start."""

    def __init__(self, i, parts):
        self.i, self.parts = i, parts
        self.bg = backdrop(COLOURS[i], B["words"][i].rstrip("."))
        self.T = sum(p.T for p in parts)
        self.final = None

    def load(self, n):
        self.cur = None

    def __call__(self, u):
        t = u * self.T
        acc = 0.0
        for p in self.parts:
            if t <= acc + p.T + 1e-9 or p is self.parts[-1]:
                break
            acc += p.T
        if p is not self.cur:
            if self.cur:
                self.cur.src.close()
            p.src.open()
            self.cur = p
        win = window(p.content(t - acc), p.bar)
        f = self.bg.copy()
        title(f, B["words"][self.i], B["lines"][self.i], ease(t / 0.5))
        sx, sy, ss = L["label"]
        label = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(label)
        d.text((sx + d.textlength(B["words"][self.i], font=font(ss, bold=True)) + 18, sy + 12),
               f"{self.i + 1}/3", font=font(26), fill=(255, 255, 255, int(170 * ease(t / 0.5))))
        base = f.convert("RGBA")
        base.alpha_composite(label)
        f = base.convert("RGB")
        put_window(f, win, dy=int(L["rise"] * (1 - back_out(t / 0.6))))
        if u >= 1:
            self.cur.src.close()
            self.cur = None
            self.final = f
        return f


def phone_tile(path, height):
    """A screenshot in a dark phone frame, as an RGBA tile."""
    w, bezel = round(height * 390 / 844), 12
    scr = Image.open(path).convert("RGB").resize((w, height), Image.Resampling.LANCZOS)
    tile = Image.new("RGBA", (w + 2 * bezel, height + 2 * bezel), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle((0, 0, tile.width - 1, tile.height - 1), 58, fill=(20, 24, 36, 255))
    tile.paste(scr, (bezel, bezel), rounded(w, height, 46))
    return tile


class Outro:
    """The three chapters as phones fanned out on navy, a small logo over them."""

    def __init__(self, T):
        self.T = T
        self.bg = gradient(*NAVY)
        self.logo = logo(L["outro_logo"][0])

    def load(self, n):
        # the recorders' "outro": the profile from the top, the feed, the job results
        shots = [os.path.join(OUT, "screens", f"o_{s}.png") for s in ("profile", "feed", "jobs")]
        self.wins = [phone_tile(p, L["phone_h"]).rotate([7, 0, -7][i], resample=Image.Resampling.BICUBIC, expand=True)
                     for i, p in enumerate(shots)]

    def __call__(self, u):
        t = u * self.T
        f = self.bg.copy().convert("RGBA")
        # the outer two first, so on the narrow phone frame the middle one sits in front
        for i in (0, 2, 1):
            tile = self.wins[i]
            k = back_out((t - 0.1 - i * 0.12) / 0.6)
            if k <= 0:
                continue
            cx = W / 2 + (i - 1) * L["fan"]
            cy = L["fan_y"] + (60 if i != 1 else 0) + 700 * (1 - k)
            f.alpha_composite(tile, (int(cx - tile.width / 2), int(cy - tile.height / 2)))
        la = ease_out((t - 0.7) / 0.6)
        if la > 0:
            lg = self.logo.copy()
            lg.putalpha(lg.getchannel("A").point(lambda v: int(v * la)))
            f.alpha_composite(lg, ((W - lg.width) // 2, int(L["outro_logo"][1] + 30 * (1 - la))))
        return f.convert("RGB")


# ---------------------------------------------------------------- the storyboard
# All scenes are recorded in one run (run.sh), so the post shows one time of day
# throughout. The times below are seconds into each scene's clip, measured on
# the recordings: re-measure them when a scene's choreography changes.
profile, feed, post, reach, jobs = Src("profile"), Src("feed"), Src("post"), Src("reach"), Src("jobs")
URL = "vutuv.de"

if not PORTRAIT:
    STORY = [
        [Part(profile, f"{URL}/miriam_kessler",
              # the finished top stands a moment (a slow 3.0-3.4) so the viewer finds their feet
              [(0.3, 3.0, 2.2), (3.0, 3.4, 0.58), (3.4, 6.3, 2.5), (6.3, 7.9, 1.0), (7.9, profile.dur - 0.1, 2.0)],
              # push in on the tag vote: the count goes 2 -> 3, the roster opens
              [(6.4, 7.8, 520, 300, 1.7)])],
        [Part(feed, f"{URL}/feed",
              # the writing in jump cuts: the first words, then the finished text; the
              # bold quicker; the first tag, then both
              [(2.0, 5.3, 2.5), (5.3, 8.9, 1.4), (8.9, 10.8, 3.0), (10.8, 12.3, 2.5), (14.6, 15.2, 2.0),
               (15.2, 19.8, 3.4), (20.6, 21.8, 2.6), (23.2, 24.0, 2.0), (24.0, feed.dur - 0.1, 1.2)],
              # the like and the repost, then the composer while she writes, bolds and tags
              [(5.5, 8.8, 620, 640, 1.6), (11.6, 23.9, 670, 400, 1.4)]),
         Part(Fedi(feed), f"{URL}/feed", [(0.0, 5.0, 2.4)]),
         # the post page, pushed in on the whole card (avatar to ⋯ menu, which then
         # opens on "Reach analysis"): the card spans x 384-1536, y 132-714
         Part(post, f"{URL}/miriam_kessler/posts", [(0.2, post.dur - 0.1, 1.3)], [(0.0, post.dur, 960, 420, 1.5)]),
         # a post that spread: its reach analysis, the reposters' audiences as growing bars
         Part(reach, f"{URL}/posts/…/analytics", [(0.2, reach.dur - 0.1, 1.2)])],
        [Part(jobs, f"{URL}/jobs",
              # after "Search" straight to the results (the reload in between flashes the
              # real unread badges before the recorder's CSS lands), and no scroll down
              [(0.2, 3.8, 2.5), (3.8, 9.1, 2.4), (9.8, 11.0, 1.0)],
              [(4.4, 8.6, 760, 400, 1.3)])],
    ]
else:
    # the phone: the same beats, measured on record_portrait.mjs's takes; a phone
    # screen is full to both edges, so only the tag vote is pushed in on (its
    # chips sit at the left, where the push keeps them)
    STORY = [
        [Part(profile, "",
              # the finished top stands a moment, the tag vote at real speed, then on
              # down through the CV and her links to the book reviews
              [(0.3, 2.8, 2.2), (2.8, 3.3, 0.58), (3.3, 6.0, 2.5), (6.0, 8.8, 1.0), (8.8, profile.dur - 0.1, 2.2)],
              [(6.3, 8.6, 300, 760, 1.35)])],
        [Part(feed, "",
              # like and repost, the composer; the writing in jump cuts as on the desktop
              [(1.2, 4.6, 2.5), (4.6, 8.4, 1.4), (8.4, 10.3, 3.0), (10.3, 11.2, 2.5), (12.4, 13.2, 2.0),
               (13.2, 18.2, 3.4), (19.3, 20.4, 2.6), (21.4, 22.2, 2.0), (22.2, feed.dur - 0.1, 1.2)]),
         Part(Fedi(feed), "", [(0.0, 5.0, 2.4)]),
         Part(post, "", [(0.2, post.dur - 0.1, 1.3)]),
         Part(reach, "", [(0.2, reach.dur - 0.1, 1.2)])],
        [Part(jobs, "",
              # a look at the list, the search, then straight to the dressed results
              # (the reload in between flashes the real unread badges), and down to them;
              # the recorder marks both moments, so this holds in either language
              [(0.2, 4.4, 2.2), (4.4, jobs.marks["search"] + 0.4, 2.4), (jobs.marks["results"], jobs.dur - 0.1, 1.1)])],
    ]

# each chapter comes in on a wipe from the one before (navy for the first), and
# a last, quicker wipe to navy leads into the end
navy = gradient(*NAVY)
SHOTS, before = [], lambda: navy
for i, parts in enumerate(STORY):
    chapter = Chapter(i, parts)
    wipe = Wipe(1.0, before, chapter.bg, B["words"][i], B["lines"][i])
    SHOTS += [(wipe.T, wipe), (chapter.T, chapter)]
    before = lambda ch=chapter: ch.final
last = Wipe(0.45, before, navy)
outro = Outro(3.4)
SHOTS += [(last.T, last), (outro.T, outro)]

if __name__ == "__main__":
    master = os.path.join(OUT, "master.mp4")
    ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                           "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", master],
                          stdin=subprocess.PIPE)
    total = 0
    for dur, fn in SHOTS:
        n = round(dur * FPS)
        if hasattr(fn, "load"):
            fn.load(n)
        for i in range(n):
            ff.stdin.write(fn(i / (n - 1)).tobytes())
        total += n
    ff.stdin.close()
    ff.wait()
    print(f"master: {total / FPS:.1f} s -> {master}")

    # delivery: H.264 (plays everywhere) and the poster (the phones under the logo)
    final = os.path.join(OUT, f"{NAME}.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", master, "-an", "-c:v", "libx264", "-preset", "veryslow",
                    "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", final], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-sseof", "-0.1", "-i", master, "-frames:v", "1",
                    os.path.join(OUT, f"{NAME}-poster.png")], check=True)
    print(f"final: {final}")
