#!/usr/bin/env python3
"""Renders Resources/Yon.icns: ink rounded square, paper arrow. Run: python3 scripts/icon.py"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

INK, PAPER = (17, 17, 17, 255), (250, 250, 247, 255)
S = 1024
root = os.path.join(os.path.dirname(__file__), "..")

im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
m = int(S * 0.08)                      # macOS icons leave a margin
d.rounded_rectangle((m, m, S - m, S - m), radius=int(S * 0.2), fill=INK)

# Arrow: shaft + head, drawn as one polygon so joins are clean.
c = S // 2
t = S * 0.055                          # half stroke width
shaft_l, shaft_r = S * 0.30, S * 0.58
head_r, head_h = S * 0.72, S * 0.19
d.polygon([
    (shaft_l, c - t), (shaft_r, c - t), (shaft_r, c - head_h),
    (head_r, c), (shaft_r, c + head_h), (shaft_r, c + t), (shaft_l, c + t),
], fill=PAPER)

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "Yon.iconset")
    os.mkdir(iconset)
    for px in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = px * scale
            name = f"icon_{px}x{px}{'@2x' if scale == 2 else ''}.png"
            im.resize((size, size), Image.Resampling.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "Resources", "Yon.icns")], check=True)
    im.resize((256, 256), Image.Resampling.LANCZOS).save(os.path.join(root, "Resources", "icon-256.png"))
print("wrote Resources/Yon.icns")
