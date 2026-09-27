"""Cuts the recorded take into the finished PDF trailer.

    python3 scripts/pdf_trailer/render.py <out_dir>

Reads  <out_dir>/rec/take/ (record.mjs: frames, marks.json, pos.json) and
       <out_dir>/logo_white_full.png
Writes <out_dir>/vutuv-pdf-trailer-de.mp4 (H.264, 1920x1080, silent) and a
       poster PNG.

The look is the teaser's backdrop (scripts/teaser/render.py): the app plays
in a browser window on the vutuv blue, the logo top right, and the camera
pushes in wherever there is something to see: the drop area, the post card,
the pages. The recording runs fast between those moments and at real speed on
them. It is cut on record.mjs's marks, so a new take needs no new numbers.
The end is the logo on the same blue.
"""
import bisect
import json
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "_build/pdf_trailer")
TAKE = os.path.join(OUT, "rec", "take")
NAME = "vutuv-pdf-trailer-de"
W, H, FPS = 1920, 1080, 30
PACE = 1.1   # one knob for the whole film's pace
MOVE = 0.9   # how long the camera takes to push in or pull out

BLUE = ((29, 66, 180), (56, 110, 245))

L = dict(cw=1500, ch=844, bar=40, wx=210, wy=150, radius=18, rise=760,
         logo=(150, 62), outline=(-30, H - 520, 560))
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


LOGO = Image.open(os.path.join(OUT, "logo_white_full.png"))
LOGO = LOGO.crop(LOGO.getbbox())


def logo(width):
    return LOGO.resize((width, int(LOGO.height * width / LOGO.width)), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------- the take
def clip():
    """The screencast frames (irregular timestamps) as a constant 30 fps clip; cached."""
    dst = os.path.join(OUT, "clips", "take.mp4")
    meta = json.load(open(os.path.join(TAKE, "frames.json")))["frames"]
    if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(os.path.join(TAKE, "frames.json")):
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
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", dst],
                         capture_output=True, text=True).stdout
    return dst, float(out.strip()), meta[0][1]


class Src:
    """Streams the clip frame by frame; reopened when a part seeks backwards."""

    def __init__(self):
        self.path, self.dur, start = clip()
        self.marks = {k: v - start for k, v in json.load(open(os.path.join(TAKE, "marks.json"))).items()}
        self.pos = json.load(open(os.path.join(TAKE, "pos.json")))
        self.p = None

    def open(self, t0=0.0):
        self.close()
        self.p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-i", self.path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.base, self.idx, self.cur = t0, -1, None

    def at(self, t):
        want = max(0, int(round((t - self.base) * FPS)))
        while self.idx < want:
            b = self.p.stdout.read(W * H * 3)
            if len(b) < W * H * 3:
                break
            self.cur, self.idx = Image.frombytes("RGB", (W, H), b), self.idx + 1
        return self.cur

    def close(self):
        if self.p:
            self.p.stdout.close()
            self.p.wait()
            self.p = None


# ---------------------------------------------------------------- the window
MASK = rounded(CW, CH + BAR, RADIUS)
SHADOW = Image.new("L", (CW + 160, CH + BAR + 160), 0)
ImageDraw.Draw(SHADOW).rounded_rectangle((80, 100, 80 + CW, 100 + CH + BAR), RADIUS, fill=120)
SHADOW = SHADOW.filter(ImageFilter.GaussianBlur(34))


def chrome(url):
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


# ---------------------------------------------------------------- the backdrop
def backdrop(colours, word):
    """The colour, a huge outline word behind the window, the logo top right."""
    g = gradient(*colours).convert("RGBA")
    x, y, size = L["outline"]
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((x, y), word, font=font(size, bold=True), fill=(255, 255, 255, 0),
                               stroke_width=3, stroke_fill=(255, 255, 255, 46))
    g.alpha_composite(layer)
    lw, ly = L["logo"]
    lg = logo(lw)
    g.alpha_composite(lg, (W - 80 - lg.width, ly))
    return g.convert("RGB")


# ---------------------------------------------------------------- the take in the window
class Part:
    """A stretch of the take in the window.

    `segs` are (s0, s1, speed) stretches, played back to back. `holds` are
    (s0, s1, cx, cy, zoom): the camera sits pushed in on (cx, cy) while the take
    is between s0 and s1, moving in before and out after over MOVE seconds.
    """

    def __init__(self, src, url, segs, holds=()):
        self.src, self.bar = src, chrome(url)
        self.segs = [(s0, s1, sp / PACE) for s0, s1, sp in segs]
        self.T = sum((s1 - s0) / sp for s0, s1, sp in self.segs)
        self.holds = [(self.film_time(a), self.film_time(b), cx, cy, z) for a, b, cx, cy, z in holds]

    def film_time(self, st):
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


class Film:
    """The whole take in one window, which rises in at the start."""

    def __init__(self, part):
        self.part = part
        self.bg = backdrop(BLUE, "PDF")
        self.T = part.T
        self.final = None

    def load(self, n):
        self.part.src.open(self.part.segs[0][0])

    def __call__(self, u):
        t = u * self.T
        f = self.bg.copy()
        put_window(f, window(self.part.content(t), self.part.bar), dy=int(L["rise"] * (1 - back_out(t / 0.6))))
        if u >= 1:
            self.final = f
        return f


class Fade:
    """From one picture to another."""

    def __init__(self, T, a, b):
        self.T, self.a, self.b = T, a, b

    def load(self, n):
        self.ia, self.ib = self.a(), self.b()

    def __call__(self, u):
        return Image.blend(self.ia, self.ib, ease(u))


class Outro:
    """The logo on the blue, and the one sentence the film is about."""

    def __init__(self, T):
        self.T = T
        self.bg = gradient(*BLUE)
        self.logo = logo(520)

    def load(self, n):
        pass

    def __call__(self, u):
        t = u * self.T
        f = self.bg.copy().convert("RGBA")
        la = ease_out(t / 0.6)
        lg = self.logo.copy()
        lg.putalpha(lg.getchannel("A").point(lambda v: int(v * la)))
        f.alpha_composite(lg, ((W - lg.width) // 2, int(400 + 30 * (1 - la))))
        sa = ease_out((t - 0.5) / 0.6)
        if sa > 0:
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            text = "PDFs an Beiträgen. Für alle Mitglieder."
            fnt = font(46)
            d.text(((W - d.textlength(text, font=fnt)) / 2, 640 + 20 * (1 - sa)), text, font=fnt, fill=(255, 255, 255, int(220 * sa)))
            f.alpha_composite(layer)
        return f.convert("RGB")


# ---------------------------------------------------------------- the storyboard
# Cut on record.mjs's marks (seconds into the take), so a new take cuts itself.
take = Src()
m, pos = take.marks, take.pos
URL = "vutuv.de/feed"
zx, zy = pos["zone"]

FILM = Film(Part(take, URL,
    # the composer opens, the text types itself quickly, the PDF flies in at real
    # speed; the click on Post, the post with its file row; the pages in the lightbox
    [(m["start"] - 0.3, m["typing"], 1.4), (m["typing"], m["typed"], 3.0),
     (m["typed"], m["drag"], 2.2), (m["drag"], m["attached"] + 1.2, 1.0),
     (m["to_submit"] - 0.2, m["to_submit"] + 1.1, 1.0), (m["to_submit"] + 1.1, m["posted"], 4.0),
     (m["posted"], m["to_preview"], 4.0),
     # the pages quickly, and out before the lightbox closes (Escape: end - 0.9)
     (m["to_preview"], m["end"] - 1.0, 2.2)],
    # pushed in on the drop area before the PDF sets off, framed wide enough
    # to hold where it starts (record.mjs: 360/150 CSS px right and below); the
    # post card and the lightbox stay whole (the lightbox's arrows sit at the
    # window's very edges), and the wait after Post runs by quickly
    [(m["typed"] + 0.3, m["attached"] + 1.0, zx + 180, zy, 1.3)]))
outro = Outro(2.0)
fade = Fade(0.5, lambda: FILM.final, lambda: outro(0.0))
SHOTS = [(FILM.T, FILM), (fade.T, fade), (outro.T, outro)]

if __name__ == "__main__":
    master = os.path.join(OUT, "master.mp4")
    ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                           "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", master],
                          stdin=subprocess.PIPE)
    total = 0
    for dur, fn in SHOTS:
        n = round(dur * FPS)
        fn.load(n)
        for i in range(n):
            ff.stdin.write(fn(i / (n - 1)).tobytes())
        total += n
    take.close()
    ff.stdin.close()
    ff.wait()
    print(f"master: {total / FPS:.1f} s -> {master}")

    final = os.path.join(OUT, f"{NAME}.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", master, "-an", "-c:v", "libx264", "-preset", "veryslow",
                    "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", final], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "4.0", "-i", master, "-frames:v", "1",
                    os.path.join(OUT, f"{NAME}-poster.png")], check=True)
    print(f"final: {final}")
