"""The post leaves Koblenz and reaches fediverse servers around the world.

Dotted world map (Natural Earth 110m via world-atlas, public domain) on the
vutuv blue, arcs from Koblenz to servers, each server pops a badge
(Simple Icons CC0 glyphs, Friendica's own logo)."""
import json, math
from PIL import Image, ImageDraw, ImageFilter

W, H = 1920, 1080
SS = 2  # supersampling for the vector overlay
BLUE_A, BLUE_B = (29, 66, 180), (37, 92, 225)
ORIGIN = (7.6, 50.36)  # Koblenz
CARD = (128, 190, 1216, 500)  # the new post in the feed frame (1920x1080)


DESTS = [  # lon, lat, badge; sorted nearest first below so they appear while the camera pulls out
    (-3.7, 40.4, "lemmy"),        # Madrid
    (24.9, 60.2, "mastodon"),     # Helsinki
    (29.0, 41.0, "friendica"),    # Istanbul
    (-21.9, 64.1, "pixelfed"),    # Reykjavik
    (36.8, -1.3, "mastodon"),     # Nairobi
    (-74.0, 40.7, "mastodon"),    # New York
    (-122.4, 37.8, "peertube"),   # San Francisco
    (-99.1, 19.4, "lemmy"),       # Mexico City
    (-46.6, -23.5, "friendica"),  # Sao Paulo
    (18.4, -33.9, "mastodon"),    # Cape Town
    (72.9, 19.1, "misskey"),      # Mumbai
    (103.8, 1.35, "pixelfed"),    # Singapore
    (127.0, 37.6, "mastodon"),    # Seoul
    (139.7, 35.7, "misskey"),     # Tokyo
    (151.2, -33.9, "friendica"),  # Sydney
]
DESTS.sort(key=lambda d: math.hypot(d[0] - ORIGIN[0], d[1] - ORIGIN[1]))


def lerp(a, b, t):
    return a + (b - a) * t


def ease(t):
    t = max(0.0, min(1.0, t))
    return 4 * t**3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ease_out(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def back_out(t, s=2.2):
    t = max(0.0, min(1.0, t)) - 1
    return t * t * ((s + 1) * t + s) + 1


def land_dots(assets, spacing=1.15):
    topo = json.load(open(f"{assets}/land-110m.json"))
    (sx, sy), (tx, ty) = topo["transform"]["scale"], topo["transform"]["translate"]
    arcs = []
    for arc in topo["arcs"]:
        x = y = 0
        pts = []
        for dx, dy in arc:
            x += dx; y += dy
            pts.append((x * sx + tx, y * sy + ty))
        arcs.append(pts)

    def ring(idxs):
        out = []
        for i in idxs:
            pts = arcs[i] if i >= 0 else arcs[~i][::-1]
            out.extend(pts if not out else pts[1:])
        return out

    PPD = 4
    mask = Image.new("L", (360 * PPD, 180 * PPD), 0)
    d = ImageDraw.Draw(mask)
    geoms = topo["objects"]["land"]
    geoms = geoms["geometries"] if geoms["type"] == "GeometryCollection" else [geoms]
    for g in geoms:
        polys = g["arcs"] if g["type"] == "MultiPolygon" else [g["arcs"]]
        for poly in polys:
            for k, r in enumerate(poly):
                # unwrap across the antimeridian, then draw the ring shifted so both halves land
                unwrapped, prev = [], None
                for lon, lat in ring(r):
                    if prev is not None:
                        while lon - prev > 180:
                            lon -= 360
                        while prev - lon > 180:
                            lon += 360
                    unwrapped.append((lon, lat))
                    prev = lon
                if len(unwrapped) < 3:
                    continue
                for shift in (-360, 0, 360):
                    pts = [((lon + shift + 180) * PPD, (90 - lat) * PPD) for lon, lat in unwrapped]
                    d.polygon(pts, fill=255 if k == 0 else 0)
    dots = []
    row = 0
    lat = 78.0
    while lat > -50:
        off = spacing / 2 if row % 2 else 0
        lon = -180 + off
        while lon < 180:
            px, py = int((lon + 180) * PPD), int((90 - lat) * PPD)
            if mask.getpixel((min(px, 360 * PPD - 1), min(py, 180 * PPD - 1))) > 128:
                dots.append((lon, lat))
            lon += spacing
        lat -= spacing * 0.866
        row += 1
    return dots


def gradient(W=W, H=H):
    g = Image.new("RGB", (W, H))
    dr = ImageDraw.Draw(g)
    for yy in range(H):
        dr.line([(0, yy), (W, yy)], fill=tuple(int(lerp(BLUE_A[i], BLUE_B[i], yy / H)) for i in range(3)))
    return g


def glow_sprite(r, color=(255, 255, 255), strength=200):
    s = r * 6
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse((s / 2 - r, s / 2 - r, s / 2 + r, s / 2 + r), fill=color + (strength,))
    return im.filter(ImageFilter.GaussianBlur(r * 0.9))


class Fediverse:
    def __init__(self, feed_frame, assets, duration=5.0, card=CARD, end_span=312, size=(W, H)):
        self.W, self.H = size
        self.T = duration
        self.feed = feed_frame.convert("RGB")
        self.card_box = card
        self.end_span = end_span  # degrees of longitude across the frame once zoomed out
        self.card = self.feed.crop(card)
        self.bg = gradient(self.W, self.H)
        self.dots = land_dots(assets)
        self.badges = {n: Image.open(f"{assets}/badges/{n}.png").convert("RGBA") for n in {d[2] for d in DESTS}}
        self.glow = glow_sprite(26)
        self.small_glow = glow_sprite(14, strength=170)
        self.launch = [1.05 + i * 0.16 for i in range(len(DESTS))]
        self.fly = 0.75

    # camera: center (lon, lat) and horizontal span in degrees; zoom is log-interpolated
    def camera(self, t):
        z = ease((t - 0.35) / 2.1)
        span = math.exp(lerp(math.log(60), math.log(self.end_span), z))
        span *= lerp(1.0, 0.96, ease((t - 3.2) / 1.8))
        clon = lerp(ORIGIN[0], 16.0, z)
        clat = lerp(ORIGIN[1], 12.0, z)
        return clon, clat, self.W / span

    def to_screen(self, lon, lat, cam):
        clon, clat, ppd = cam
        return (self.W / 2 + (lon - clon) * ppd, self.H / 2 - (lat - clat) * ppd)

    def arc_point(self, p0, p1, u):
        mx, my = (p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2
        dx, dy = p1[0] - p0[0], p1[1] - p0[1]
        dist = math.hypot(dx, dy)
        cx, cy = mx, my - dist * 0.32
        x = (1 - u) ** 2 * p0[0] + 2 * (1 - u) * u * cx + u**2 * p1[0]
        y = (1 - u) ** 2 * p0[1] + 2 * (1 - u) * u * cy + u**2 * p1[1]
        return x, y

    def __call__(self, u):
        t = u * self.T
        cam = self.camera(t)
        frame = self.bg.copy()

        ov = Image.new("RGBA", (self.W * SS, self.H * SS), (0, 0, 0, 0))
        d = ImageDraw.Draw(ov)
        map_alpha = ease_out((t - 0.1) / 0.8)
        # dots
        ppd = cam[2]
        r = max(1.6, 0.30 * 1.15 * ppd) * SS
        a = int(62 * map_alpha)
        for lon, lat in self.dots:
            x, y = self.to_screen(lon, lat, cam)
            if -30 < x < self.W + 30 and -30 < y < self.H + 30:
                d.ellipse((x * SS - r, y * SS - r, x * SS + r, y * SS + r), fill=(255, 255, 255, a))
        # arcs
        o = self.to_screen(*ORIGIN, cam)
        arrivals = []
        for i, (lon, lat, name) in enumerate(DESTS):
            k = (t - self.launch[i]) / self.fly
            if k <= 0:
                continue
            p1 = self.to_screen(lon, lat, cam)
            prog = ease_out(min(k, 1.0))
            n = 48
            pts = [self.arc_point(o, p1, prog * j / n) for j in range(n + 1)]
            fade = 1.0 if k < 1.4 else max(0.35, 1.0 - (k - 1.4) * 0.5)
            d.line([(x * SS, y * SS) for x, y in pts], fill=(255, 255, 255, int(170 * fade)), width=3 * SS, joint="curve")
            if k < 1.0:
                hx, hy = pts[-1]
                rr = 6 * SS
                d.ellipse((hx * SS - rr, hy * SS - rr, hx * SS + rr, hy * SS + rr), fill=(255, 255, 255, 255))
            else:
                arrivals.append((i, p1, k - 1.0, name))
        ov = ov.resize((self.W, self.H), Image.Resampling.LANCZOS)
        frame.paste(ov, (0, 0), ov)

        # feed frame fading out, card shrinking into Koblenz
        if t < 1.0:
            ff = 1 - ease_out(t / 0.55)
            if ff > 0:
                frame = Image.blend(frame, self.feed, ff)
            k = ease(t / 0.95)
            cx0, cy0 = (self.card_box[0] + self.card_box[2]) / 2, (self.card_box[1] + self.card_box[3]) / 2
            cx, cy = lerp(cx0, o[0], k), lerp(cy0, o[1], k)
            s = lerp(1.0, 0.02, k)
            cw, ch = max(2, int(self.card.width * s)), max(2, int(self.card.height * s))
            card = self.card.resize((cw, ch), Image.Resampling.LANCZOS).convert("RGBA")
            card.putalpha(int(255 * (1 - ease((t - 0.55) / 0.4))))
            frame.paste(card, (int(cx - cw / 2), int(cy - ch / 2)), card)

        # origin glow
        pulse = 1 + 0.15 * math.sin(t * 6)
        g = self.glow.resize((int(self.glow.width * pulse), int(self.glow.height * pulse)))
        ga = ease_out((t - 0.7) / 0.4)
        if ga > 0:
            g.putalpha(g.getchannel("A").point(lambda v: int(v * ga)))
            frame.paste(g, (int(o[0] - g.width / 2), int(o[1] - g.height / 2)), g)
            dd = ImageDraw.Draw(frame)
            rr = 9 * ga
            dd.ellipse((o[0] - rr, o[1] - rr, o[0] + rr, o[1] + rr), fill=(255, 255, 255))

        # arrival rings and badges
        for i, p1, since, name in arrivals:
            if since < 0.6:
                rr = lerp(10, 60, ease_out(since / 0.6))
                ring = Image.new("RGBA", (self.W, self.H), (0, 0, 0, 0))
                ImageDraw.Draw(ring).ellipse((p1[0] - rr, p1[1] - rr, p1[0] + rr, p1[1] + rr), outline=(255, 255, 255, int(200 * (1 - since / 0.6))), width=3)
                frame.paste(ring, (0, 0), ring)
            sc = back_out(since / 0.45)
            size = int(58 * sc)
            if size > 4:
                sg = self.small_glow
                frame.paste(sg, (int(p1[0] - sg.width / 2), int(p1[1] - sg.height / 2)), sg)
                b = self.badges[name].resize((size, size), Image.Resampling.LANCZOS)
                frame.paste(b, (int(p1[0] - size / 2), int(p1[1] - size / 2)), b)
        return frame
