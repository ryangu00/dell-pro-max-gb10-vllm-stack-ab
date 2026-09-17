#!/usr/bin/env python3
"""Draw the repo banner. Pure PIL, no generated imagery — matches the RyanAI Lab house style.

Concept: text and image collapse into one vector space; a query finds the right point.
Left = the wordmark. Right = a scatter of corpus points with one orange hit, reached by a
dashed query line from a TEXT source and an IMAGE source that share the same space.
"""
import pathlib
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
BG = (10, 10, 10)
WHITE = (245, 245, 245)
GREY = (140, 140, 140)
DIM = (70, 70, 70)
ORANGE = (255, 122, 26)
OUT = pathlib.Path(__file__).resolve().parents[1] / "docs/assets/banner.png"

HN = "/System/Library/Fonts/HelveticaNeue.ttc"
MENLO = "/System/Library/Fonts/Menlo.ttc"


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except Exception:
        return ImageFont.load_default()


f_title = font(HN, 88, 7)     # index 7 = Light
f_tag = font(HN, 27, 1)       # index 1 = Bold (3 is Bold Italic — verified with getname())
f_mono = font(MENLO, 15)
f_label = font(MENLO, 12)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

# ── corner crosshairs ─────────────────────────────────────────────────────────
for cx, cy in ((38, 38), (W - 38, 38), (38, H - 38), (W - 38, H - 38)):
    d.line([(cx - 11, cy), (cx + 11, cy)], fill=DIM, width=1)
    d.line([(cx, cy - 11), (cx, cy + 11)], fill=DIM, width=1)

# ── 5x3 dot lattices ──────────────────────────────────────────────────────────
for ox, oy in ((72, 78), (1150, 536)):
    for r in range(3):
        for c in range(5):
            x, y = ox + c * 15, oy + r * 12
            d.ellipse([x, y, x + 1.6, y + 1.6], fill=DIM)

# ── wordmark ──────────────────────────────────────────────────────────────────
d.text((80, 196), "VLLM STACK", font=f_title, fill=WHITE)
d.text((80, 288), "A/B", font=f_title, fill=WHITE)
d.text((82, 414), "Measure the stack like you measure the model.", font=f_tag, fill=WHITE)
d.text((82, 462), "2× GB10 · TP2 · 284B MOE · FOUR STACKS · ONE RULE", font=f_mono, fill=GREY)

# ── right: the embedding space ────────────────────────────────────────────────
CX, CY, R = 950, 318, 138
d.ellipse([CX - R, CY - R, CX + R, CY + R], outline=(52, 52, 52), width=1)

# corpus points — deterministic scatter (no RNG, so the banner is reproducible)
pts = [(-96, -58), (-54, -104), (12, -118), (74, -84), (108, -26), (100, 44),
       (58, 96), (-4, 116), (-66, 92), (-108, 34), (-42, -34), (26, -52),
       (62, 18), (-18, 46), (-72, 6), (34, 74)]
for dx, dy in pts:
    x, y = CX + dx, CY + dy
    d.ellipse([x - 2.4, y - 2.4, x + 2.4, y + 2.4], fill=(96, 96, 96))

# the hit
hx, hy = CX + 26, CY - 52
d.ellipse([hx - 5.5, hy - 5.5, hx + 5.5, hy + 5.5], fill=ORANGE)
d.text((hx + 16, hy - 7), "WINNER", font=f_label, fill=ORANGE)

# two sources feeding the same space
d.text((672, 236), "STACK", font=f_label, fill=GREY)
d.text((664, 392), "IMAGE", font=f_label, fill=GREY)
for sy, ty in ((242, hy - 14), (398, hy + 16)):
    x = 726
    while x < hx - 22:
        seg = min(7, hx - 22 - x)
        yy = sy + (ty - sy) * ((x - 726) / max(hx - 22 - 726, 1))
        d.line([(x, yy), (x + seg, yy)], fill=(88, 88, 88), width=1)
        x += 13

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print(f"wrote {OUT} ({OUT.stat().st_size // 1024}KB)")
