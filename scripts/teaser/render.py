"""Cuts the recorded scenes into the finished teaser.

    python3 scripts/teaser/render.py <lang>              # 1920x1080, the desktop cut
    python3 scripts/teaser/render.py <lang> --portrait   # 1080x1920, the phone cut

Reads  _build/teaser/<lang>/rec/<scene>/ (record.mjs), screens/ and ids.json,
       _build/teaser/<lang>/portrait/rec/ and screens/ (record_portrait.mjs),
       _build/teaser/assets/ (assets.py, render_assets.mjs)
Writes _build/teaser/<lang>/master.mp4 (near-lossless) and, via export,
       _build/teaser/<lang>/vutuv-teaser-<lang>.mp4 plus a poster PNG;
       the portrait cut the same under _build/teaser/<lang>/portrait/, named
       vutuv-teaser-<lang>-portrait.*

The storyboard lives in SHOTS below; README.md explains each shot.
"""
import bisect
import io
import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(__file__))
from fediverse import Fediverse  # noqa: E402
from savepdf import SavePdf  # noqa: E402

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
PORTRAIT = "--portrait" in sys.argv
LANG = ARGS[0] if ARGS else "de"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "_build", "teaser", LANG, *(["portrait"] if PORTRAIT else []))
NAME = f"vutuv-teaser-{LANG}" + ("-portrait" if PORTRAIT else "")
ASSETS = os.path.join(ROOT, "_build", "teaser", "assets")
CONTENT = json.load(open(os.path.join(os.path.dirname(__file__), f"content.{LANG}.json")))
W, H, FPS = (1080, 1920, 30) if PORTRAIT else (1920, 1080, 30)
BLUE_A, BLUE_B = (29, 66, 180), (37, 92, 225)


def ease(t):
    t = max(0.0, min(1.0, t))
    return 4 * t**3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ease_out(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def lerp(a, b, t):
    return a + (b - a) * t


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


def frame_at(path, t):
    png = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", path, "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"], capture_output=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGB")


class Live:
    """A stretch [s0, s1] of a scene clip, time-remapped onto the shot's duration."""

    def __init__(self, scene, s0, s1_from_end, fade_from=None, fade=0.4):
        self.path, dur = clip(scene)
        self.s0, self.s1 = s0, dur - s1_from_end
        self.fade_from, self.fade = fade_from, fade
        self.frames, self.prev = None, None

    def load(self, n):
        want = sorted({round((self.s0 + (self.s1 - self.s0) * i / (n - 1)) * FPS) for i in range(n)})
        first = want[0]
        p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{first / FPS:.4f}", "-i", self.path, "-frames:v", str(want[-1] - first + 1),
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        self.frames, idx, keep = {}, first, set(want)
        while True:
            b = p.stdout.read(W * H * 3)
            if len(b) < W * H * 3:
                break
            if idx in keep:
                self.frames[idx] = Image.frombytes("RGB", (W, H), b)
            idx += 1
        p.wait()
        self.prev = self.fade_from() if self.fade_from else None
        self.n = n

    def unload(self):
        self.frames, self.prev = None, None

    def __call__(self, u):
        want = round((self.s0 + (self.s1 - self.s0) * u) * FPS)
        f = self.frames.get(want) or self.frames[max(k for k in self.frames if k <= want)]
        dur = self.n / FPS
        if self.prev is not None and u * dur < self.fade:
            k = ease(u * dur / self.fade)
            f = Image.blend(self.prev, f, k)
        return f

    def last(self):
        return frame_at(self.path, self.s1)


# ---------------------------------------------------------------- drawn pieces
def gradient():
    g = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(g)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=tuple(int(lerp(BLUE_A[i], BLUE_B[i], y / H)) for i in range(3)))
    return g


BG = gradient()
LOGO = Image.open(os.path.join(ASSETS, "logo_white_full.png"))
LOGO = LOGO.crop(LOGO.getbbox())


def endcard(u):
    f = BG.copy()
    lw = int(min(760, W * 0.68) * lerp(0.9, 1.0, ease_out(u * 3.4)))
    lh = int(LOGO.height * lw / LOGO.width)
    lg = LOGO.resize((lw, lh), Image.Resampling.LANCZOS)
    f.paste(lg, ((W - lw) // 2, (H - lh) // 2), lg)
    return f


# the opening's phones: three side by side, as large as the frame's width allows
PH_H = 640 if PORTRAIT else 900
PH_W = round(PH_H * 390 / 844)
SPREAD = 350 if PORTRAIT else 520  # how far the outer two sit from the middle one


def rounded_mask(w, h, r):
    m = Image.new("L", (w * 2, h * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * 2 - 1, h * 2 - 1), r * 2, fill=255)
    return m.resize((w, h), Image.Resampling.LANCZOS)


MASK = rounded_mask(PH_W, PH_H, 46)
SHADOW = Image.new("L", (PH_W + 120, PH_H + 120), 0)
ImageDraw.Draw(SHADOW).rounded_rectangle((60, 70, 60 + PH_W, 70 + PH_H), 46, fill=110)
SHADOW = SHADOW.filter(ImageFilter.GaussianBlur(28))


class PhoneMorph:
    """Three phones; the outer ones leave while the middle one grows into the desktop feed."""

    def __init__(self, desk, T):
        self.T = T
        self.shots = {n: Image.open(os.path.join(OUT, "screens", f"{n}.png")).convert("RGB") for n in ("mA", "mB", "mC")}
        # the outer two only ever show at phone size: resize them once, not per frame
        self.small = {n: self.shots[n].resize((PH_W, PH_H), Image.Resampling.LANCZOS) for n in ("mA", "mC")}
        self.desk = desk
        self.page_bg = desk.getpixel((40, 600))

    def __call__(self, u):
        t = u * self.T
        f = BG.copy()
        # Something moves from the first frame on and the phones hold only half
        # a second: a long still opening read as "nothing is going to happen".
        arrive = ease_out(min(1, t / 0.7))
        leave = ease((t - 1.2) / 0.8)
        grow = ease((t - 1.4) / 1.4)
        for name, cx, dy, dx in [("mA", W / 2 - SPREAD, 140, -1), ("mC", W / 2 + SPREAD, 300, 1)]:
            if leave >= 1:
                continue
            scr = self.small[name]
            x = int(cx - PH_W / 2 + dx * leave * 700)
            y = int((H - PH_H) / 2 + dy * (1 - arrive))
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            layer.paste((0, 0, 0, 255), (x - 60, y - 60), SHADOW)
            layer.paste(scr, (x, y), MASK)
            layer.putalpha(layer.getchannel("A").point(lambda v: int(v * (1 - leave))))
            f.paste(layer, (0, 0), layer)
        x = lerp(W / 2 - PH_W / 2, 0, grow)
        y = lerp((H - PH_H) / 2 + 220 * (1 - arrive), 0, grow)
        w, h = int(round(lerp(PH_W, W, grow))), int(round(lerp(PH_H, H, grow)))
        mob = self.shots["mB"]
        mob_s = mob.resize((w, int(mob.height * w / mob.width)), Image.Resampling.BICUBIC).crop((0, 0, w, h))
        desk_s = Image.new("RGB", (w, h), self.page_bg)
        desk_s.paste(self.desk.resize((w, int(self.desk.height * w / self.desk.width)), Image.Resampling.BICUBIC), (0, 0))
        screen = Image.blend(mob_s, desk_s, ease((grow - 0.15) / 0.55))
        if grow >= 1:
            return screen
        m = rounded_mask(w, h, max(1, int(lerp(46, 0, grow))))
        if grow < 0.6:
            sh = SHADOW.resize((w + 120, h + 120)).point(lambda v: int(v * (1 - grow / 0.6)))
            f.paste((0, 0, 0), (int(x) - 60, int(y) - 60), sh)
        f.paste(screen, (int(x), int(y)), m)
        return f


# ---------------------------------------------------------------- the storyboard
# the feed has built itself here; the pointer comes in right after
FEED_T0 = 1.6 if PORTRAIT else 4.0


def screens_json(name):
    return json.load(open(os.path.join(OUT, "screens", name)))


feed = Live("feed", FEED_T0, 0.3)
feed_last = feed.last()
# the phone's post card and a narrower world, to fill more of the tall frame
fedi_geometry = {"card": tuple(screens_json("card.json")), "end_span": 300} if PORTRAIT else {}
fedi = Fediverse(feed_last, ASSETS, duration=5.0, size=(W, H), **fedi_geometry)
post = Live("post", 0.3, 0.1, fade_from=lambda: fedi(1.0), fade=0.45)
chat = Live("chat", 0.3, 0.2)
job = Live("job", 0.3, 0.1, fade_from=lambda: chat.last(), fade=0.35)
jobs = Live("jobs", 0.2, 0.1, fade_from=lambda: job.last(), fade=0.35)
owner = Live("owner", 0.3, 0.1, fade_from=lambda: jobs.last(), fade=0.35)
cv = Live("cv", 0.2, 0.1, fade_from=lambda: owner.last(), fade=0.4)
printv = Live("print", 0.2, 0.1, fade_from=lambda: cv.last(), fade=0.35)
# where the printed sheet sits in the phone's print view (measured when recording)
sheet_geometry = dict(zip(("sheet_x0", "sheet_w"), screens_json("sheet.json")), file_w=460) if PORTRAIT else {}
save = SavePdf(os.path.join(OUT, "screens", "cv_sheet.png"), CONTENT["pdf_name"], size=(W, H), **sheet_geometry)
print_last = printv.last()
morph = PhoneMorph(frame_at(feed.path, FEED_T0), 3.0)


def speed(live, factor):
    """A shot that plays its stretch `factor` times faster than it was recorded."""
    return ((live.s1 - live.s0) / factor, live)


SHOTS = [
    (morph.T, morph),                             # three phones, the middle one becomes the feed
    speed(feed, 1.25),                            # like + repost the news, write, bold, tag, post
    (fedi.T, fedi),                               # the post flies out to the fediverse
    speed(post, 1.07),                            # likes, Anna's reply, a DM arrives
    speed(chat, 1.30),                            # Anna's DM with the job link, Miriam opens it
    speed(job, 1.28),                             # the posting, then on to the job board
    speed(jobs, 1.29),                            # search Elixir + city + radius, then her profile
    speed(owner, 1.21),                           # her profile builds itself, "open CV"
    speed(cv, 1.14),                              # untick the photo, print
    speed(printv, 1.10),                          # the print view without photo
    (save.T, lambda u: save(u, print_last)),      # saved as PDF into the download folder
    (2.4, endcard),                               # the logo
]

if __name__ == "__main__":
    master = os.path.join(OUT, "master.mp4")
    ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                           "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", master],
                          stdin=subprocess.PIPE)
    total = 0
    for dur, fn in SHOTS:
        n = round(dur * FPS)
        if isinstance(fn, Live):
            fn.load(n)
        for i in range(n):
            ff.stdin.write(fn(i / (n - 1)).tobytes())
        if isinstance(fn, Live):
            fn.unload()
        total += n
    ff.stdin.close()
    ff.wait()
    print(f"master: {total / FPS:.1f} s -> {master}")

    # delivery: H.264 1080p (plays everywhere) and the poster (the three phones)
    final = os.path.join(OUT, f"{NAME}.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", master, "-an", "-c:v", "libx264", "-preset", "veryslow", "-tune", "animation",
                    "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart", final], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "0.9", "-i", master, "-frames:v", "1", os.path.join(OUT, f"{NAME}-poster.png")], check=True)
    print(f"final: {final}")
