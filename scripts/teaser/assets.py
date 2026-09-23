"""Download and prepare the static inputs of the teaser into _build/teaser/assets.

    python3 scripts/teaser/assets.py

Sources and licences (checked 2026-09-23):
  * Miriam's portrait: Jake Nackos on Unsplash (Unsplash License)
    https://unsplash.com/photos/woman-in-white-crew-neck-shirt-smiling-IF9TK5Uy-KI
  * Koblenz panorama (cover): Maxime Vandenberge on Unsplash (Unsplash License)
    https://unsplash.com/photos/a-city-next-to-a-body-of-water-9wUQEBf03D0
  * World map: Natural Earth 110m land via the world-atlas npm package (public domain)
  * Network glyphs: Simple Icons (CC0); Friendica's own logo from its repository
Files already present are kept, so a second run is offline.
"""
import os
import urllib.request
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "_build", "teaser", "assets")
OUT = os.path.abspath(OUT)
os.makedirs(os.path.join(OUT, "icons"), exist_ok=True)

DOWNLOADS = {
    "raw_avatar.jpg": "https://images.unsplash.com/photo-1580489944761-15a19d654956?w=1400&q=90&fm=jpg",
    "raw_cover.jpg": "https://images.unsplash.com/photo-1655386278428-7b4064a5d697?w=2600&q=88&fm=jpg",
    "land-110m.json": "https://cdn.jsdelivr.net/npm/world-atlas@2/land-110m.json",
    "icons/friendica.svg": "https://cdn.jsdelivr.net/gh/friendica/friendica@stable/images/friendica.svg",
}
for name in ["mastodon", "pixelfed", "misskey", "peertube", "lemmy"]:
    DOWNLOADS[f"icons/{name}.svg"] = f"https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/{name}.svg"

for name, url in DOWNLOADS.items():
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        continue
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
        f.write(r.read())
    print("fetched", name)

# square portrait (face centred) and a 4:1 cover showing the Rhine bend
avatar = Image.open(os.path.join(OUT, "raw_avatar.jpg")).convert("RGB")
avatar.crop((0, 60, 1400, 1460)).resize((1000, 1000), Image.LANCZOS).save(os.path.join(OUT, "miriam_avatar.jpg"), quality=92)
cover = Image.open(os.path.join(OUT, "raw_cover.jpg")).convert("RGB")
w, h = cover.size
top = int(h * 0.30)
cover.crop((0, top, w, top + w // 4)).save(os.path.join(OUT, "miriam_cover.jpg"), quality=90)
print("assets ready in", OUT)
