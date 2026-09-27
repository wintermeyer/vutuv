"""Cuts the recorded take into the finished PDF trailer.

    python3 scripts/pdf_trailer/render.py <out_dir>

Reads  <out_dir>/frames.json and frames/ (record.mjs), logo_white_full.png
Writes <out_dir>/vutuv-pdf-trailer-de.mp4 (H.264, 1920x1080, silent) and a
       poster PNG.

The screencast hands frames over at irregular times; each output frame takes
the newest recorded frame at its moment, so the take plays at its real pace.
The end is the vutuv logo on the brand blue, faded in from the last frame.
"""
import bisect
import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "_build/pdf_trailer")
W, H, FPS = 1920, 1080, 30
BLUE_A, BLUE_B = (29, 66, 180), (37, 92, 225)


def ease(t):
    t = max(0.0, min(1.0, t))
    return 4 * t**3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def background():
    g = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(g)
    for y in range(H):
        k = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(BLUE_A[i] + (BLUE_B[i] - BLUE_A[i]) * k) for i in range(3)))
    return g


def endcard():
    f = background()
    logo = Image.open(os.path.join(OUT, "logo_white_full.png"))
    logo = logo.crop(logo.getbbox())
    lw = 720
    lh = int(logo.height * lw / logo.width)
    logo = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    f.paste(logo, ((W - lw) // 2, (H - lh) // 2), logo)
    return f


def main():
    meta = json.load(open(os.path.join(OUT, "frames.json")))["frames"]
    ts = [t for _, t in meta]
    start, end = ts[0] + 0.4, ts[-1] + 0.3
    final = os.path.join(OUT, "vutuv-pdf-trailer-de.mp4")
    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
         "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", final],
        stdin=subprocess.PIPE)
    last_img, last_j = None, None
    for i in range(int((end - start) * FPS)):
        j = max(0, bisect.bisect_right(ts, start + i / FPS) - 1)
        if j != last_j:
            last_img = Image.open(meta[j][0]).convert("RGB")
            if last_img.size != (W, H):
                last_img = last_img.resize((W, H), Image.Resampling.LANCZOS)
            last_j = j
        ff.stdin.write(last_img.tobytes())
    card = endcard()
    fade = int(0.6 * FPS)
    for i in range(fade):
        ff.stdin.write(Image.blend(last_img, card, ease(i / (fade - 1))).tobytes())
    for _ in range(int(2.2 * FPS)):
        ff.stdin.write(card.tobytes())
    ff.stdin.close()
    ff.wait()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "3.0", "-i", final, "-frames:v", "1",
                    os.path.join(OUT, "vutuv-pdf-trailer-de-poster.png")], check=True)
    print("final", final)


if __name__ == "__main__":
    main()
