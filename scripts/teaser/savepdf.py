"""The finished CV leaves the print view, becomes a PDF file and is saved into a download folder."""
import math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
BLUE_A, BLUE_B = (29, 66, 180), (37, 92, 225)
PAGE_BG = (240, 243, 249)
SHEET_X0 = 390  # where the sheet sits in the print-view frame (1920 wide)


def lerp(a, b, t):
    return a + (b - a) * t


def clamp(t):
    return max(0.0, min(1.0, t))


def ease(t):
    t = clamp(t)
    return 4 * t**3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ease_out(t):
    t = clamp(t)
    return 1 - (1 - t) ** 3


def back_out(t, s=1.9):
    t = clamp(t) - 1
    return t * t * ((s + 1) * t + s) + 1


def gradient():
    g = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(g)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=tuple(int(lerp(BLUE_A[i], BLUE_B[i], y / H)) for i in range(3)))
    return g


def font(size, bold=False):
    try:
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)
    except Exception:
        return ImageFont.load_default()


class SavePdf:
    def __init__(self, sheet_path, name, duration=4.8):
        self.T = duration
        self.sheet = Image.open(sheet_path).convert("RGB")
        # an A4 page: crop the sheet to 1:1.414
        sw = self.sheet.width
        self.page = self.sheet.crop((0, 0, sw, min(self.sheet.height, int(sw * 1.414))))
        if self.page.height < int(sw * 1.414):
            p = Image.new("RGB", (sw, int(sw * 1.414)), "white")
            p.paste(self.page, (0, 0))
            self.page = p
        self.bg = gradient()
        self.name = name
        self.f_name = font(30, bold=True)
        self.f_badge = font(34, bold=True)
        self.folder = self._folder(260)

    def _doc(self, w, fold_t, badge_t):
        """The page as a file icon: rounded, folded corner, red PDF badge."""
        h = int(w * 1.414)
        page = self.page.resize((w, h), Image.Resampling.LANCZOS).convert("RGBA")
        d = ImageDraw.Draw(page)
        fold = int(w * 0.16 * ease_out(fold_t))
        if fold > 2:
            d.polygon([(w - fold, 0), (w, 0), (w, fold)], fill=(0, 0, 0, 0))
            d.polygon([(w - fold, 0), (w - fold, fold), (w, fold)], fill=(214, 222, 236, 255))
        mask = Image.new("L", (w * 2, h * 2), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * 2 - 1, h * 2 - 1), max(2, w // 18), fill=255)
        mask = mask.resize((w, h), Image.Resampling.LANCZOS)
        if fold > 2:
            ImageDraw.Draw(mask).polygon([(w - fold, 0), (w, 0), (w, fold)], fill=0)
        page.putalpha(mask)
        if badge_t > 0:
            s = back_out(badge_t)
            bw, bh = int(w * 0.46 * s), int(w * 0.2 * s)
            if bw > 6 and bh > 6:
                badge = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
                bd = ImageDraw.Draw(badge)
                bd.rounded_rectangle((0, 0, bw - 1, bh - 1), bh // 4, fill=(220, 38, 38, 255))
                f = font(max(8, int(bh * 0.62)), bold=True)
                tw = bd.textlength("PDF", font=f)
                bd.text(((bw - tw) / 2, bh * 0.14), "PDF", font=f, fill="white")
                page.alpha_composite(badge, (int(w * 0.08), int(h * 0.8 - bh / 2)))
        return page

    def _folder(self, w):
        h = int(w * 0.78)
        im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        tab = (int(w * 0.06), 0, int(w * 0.46), int(h * 0.3))
        d.rounded_rectangle(tab, int(h * 0.08), fill=(191, 219, 254, 255))
        d.rounded_rectangle((0, int(h * 0.12), w - 1, h - 1), int(h * 0.1), fill=(219, 234, 254, 255))
        d.rounded_rectangle((0, int(h * 0.24), w - 1, h - 1), int(h * 0.1), fill=(255, 255, 255, 255))
        # a download arrow on the front
        cx, cy = w / 2, h * 0.62
        s = h * 0.2
        d.line([(cx, cy - s), (cx, cy + s * 0.55)], fill=(37, 88, 217, 255), width=max(4, int(w * 0.04)))
        d.polygon([(cx - s * 0.6, cy + s * 0.05), (cx + s * 0.6, cy + s * 0.05), (cx, cy + s * 0.75)], fill=(37, 88, 217, 255))
        d.line([(cx - s * 0.9, cy + s * 1.05), (cx + s * 0.9, cy + s * 1.05)], fill=(37, 88, 217, 255), width=max(4, int(w * 0.035)))
        return im

    def _shadow(self, w, h, strength):
        pad = 60
        sh = Image.new("L", (w + pad * 2, h + pad * 2), 0)
        ImageDraw.Draw(sh).rounded_rectangle((pad, pad + 14, pad + w, pad + h + 14), 24, fill=int(120 * strength))
        return sh.filter(ImageFilter.GaussianBlur(22)), pad

    def __call__(self, u, first_frame):
        t = u * self.T
        # 0.0 - 1.1: background turns blue while the page lifts off the print view
        bg_k = ease((t - 0.1) / 0.9)
        # the lifted sheet replaces the one in the print view, so the view underneath is left empty
        under = first_frame.convert("RGB").copy()
        ImageDraw.Draw(under).rectangle((SHEET_X0, 0, SHEET_X0 + 1140, H), fill=PAGE_BG)
        f = Image.blend(under, self.bg, bg_k) if bg_k < 1 else self.bg.copy()

        lift = ease((t - 0.1) / 1.1)
        # the sheet starts at its print-view size (1140 wide, top at y=0) and becomes a 360-wide file
        w_start, w_file = 1140, 360
        # 2.3 - 3.2: the file shrinks into the folder
        drop = ease((t - 2.4) / 0.9)
        w = int(lerp(lerp(w_start, w_file, lift), 120, drop))
        h = int(w * 1.414)
        cx = lerp(lerp(SHEET_X0 + w_start / 2, W / 2, lift), W / 2, drop)
        top_file = (H - int(w_file * 1.414)) / 2 - 40
        folder_y = H - 330
        cy_top = lerp(lerp(0, top_file, lift), folder_y + 20, drop)

        # folder rises in from below at 1.9
        fold_in = ease_out((t - 1.9) / 0.6)
        bounce = 0
        if t > 3.25:
            bounce = math.sin(clamp((t - 3.25) / 0.45) * math.pi) * 18
        # once saved, the folder settles in the middle of the frame
        settle = ease((t - 3.9) / 0.6)
        folder_y_now = lerp(folder_y, (H - self.folder.height) / 2, settle)
        if fold_in > 0:
            fx = int(W / 2 - self.folder.width / 2)
            fy = int(lerp(H + 20, folder_y_now, fold_in) + bounce)
            f.paste(self.folder, (fx, fy), self.folder)

        if drop < 0.98:
            doc = self._doc(w, (t - 0.9) / 0.4, (t - 1.2) / 0.5)
            sh, pad = self._shadow(w, h, lift * (1 - drop))
            x, y = int(cx - w / 2), int(cy_top)
            f.paste((0, 0, 0), (x - pad, y - pad), sh)
            if drop > 0.75:
                a = doc.getchannel("A").point(lambda v: int(v * (1 - (drop - 0.75) / 0.23)))
                doc.putalpha(a)
            f.paste(doc, (x, y), doc)

        # file name under the file while it is large
        name_k = ease((t - 1.4) / 0.4) * (1 - ease((t - 2.3) / 0.3))
        if name_k > 0.01:
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            tw = d.textlength(self.name, font=self.f_name)
            y = top_file + int(w_file * 1.414) + 26
            d.text(((W - tw) / 2, y), self.name, font=self.f_name, fill=(255, 255, 255, int(255 * name_k)))
            f.paste(layer, (0, 0), layer)

        # saved: a green check on the folder
        ok = back_out((t - 3.4) / 0.4)
        if t > 3.4:
            r = int(46 * ok)
            if r > 3:
                fx = W / 2 + self.folder.width / 2 - 30
                fy = folder_y_now + 30 + bounce
                d = ImageDraw.Draw(f)
                d.ellipse((fx - r, fy - r, fx + r, fy + r), fill=(22, 163, 74))
                s = r / 46
                d.line([(fx - 20 * s, fy + 1 * s), (fx - 5 * s, fy + 16 * s), (fx + 22 * s, fy - 14 * s)], fill="white", width=max(3, int(9 * s)), joint="curve")
        return f
