#!/usr/bin/env python3
"""Generate the PENTA mark.

Five strokes on a pentagon, with one segment broken to leave a gap — reads as a
'P' aperture at small sizes and as a pentagon at large ones. Wholly original;
see docs/LEGAL.md for why that matters.

Generated rather than hand-drawn so the boot splash, the menu and any future
export stay pixel-identical and re-derivable at any size.

    ./tools/make-logo.py
"""

from __future__ import annotations

import math
import pathlib
import sys

from PIL import Image, ImageDraw

SIZE = 512
SUPERSAMPLE = 4            # draw big, downscale: cheap antialiasing
STROKE = 34
GAP_DEGREES = 46           # the aperture, at the top-right vertex

OUTPUTS = [
    "image/mkosi/mkosi.extra/usr/share/penta/logo.png",
    "image/mkosi/mkosi.extra/usr/share/plymouth/themes/penta/logo.png",
    "menu/assets/logo.png",
]


def pentagon(cx: float, cy: float, r: float, n: int = 5):
    """Vertices starting at the top, going clockwise."""
    return [
        (cx + r * math.sin(2 * math.pi * i / n),
         cy - r * math.cos(2 * math.pi * i / n))
        for i in range(n)
    ]


def draw_mark(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    r = size * 0.36
    cx = cy = size / 2
    stroke = int(STROKE * size / SIZE)
    pts = pentagon(cx, cy, r)

    for i in range(5):
        a, b = pts[i], pts[(i + 1) % 5]
        if i == 0:
            # Break the first edge to leave the aperture. Shortening from the
            # 'b' end keeps the top vertex crisp.
            t = 1.0 - GAP_DEGREES / 180.0
            b = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        d.line([a, b], fill=(255, 255, 255, 255), width=stroke)
        # Round the joints: PIL has no line-join control, so cap them manually.
        for p in (a, b):
            d.ellipse([p[0] - stroke / 2, p[1] - stroke / 2,
                       p[0] + stroke / 2, p[1] + stroke / 2],
                      fill=(255, 255, 255, 255))

    # Centre dot — the fifth point, and it stops the mark reading as an empty
    # outline at splash-screen scale.
    dot = r * 0.13
    d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot],
              fill=(255, 255, 255, 255))
    return img


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    big = draw_mark(SIZE * SUPERSAMPLE)
    mark = big.resize((SIZE, SIZE), Image.LANCZOS)

    for rel in OUTPUTS:
        out = root / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        mark.save(out)
        print(f"wrote {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
