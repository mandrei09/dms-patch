#!/usr/bin/python3 -I
"""crop.py FROZEN OUT SCALE X Y W H [POINTS]

Cut a snip out of the frozen monitor capture. X/Y/W/H are logical
(overlay) coordinates; SCALE converts them to the capture's physical pixels.
POINTS ("x,y x,y ...", logical, absolute) makes it a freeform snip: the
outline becomes the alpha mask, everything outside it transparent.
"""
import sys

import cairo

frozen, out = sys.argv[1], sys.argv[2]
scale, x, y, w, h = (float(v) for v in sys.argv[3:8])
points = sys.argv[8].split() if len(sys.argv) > 8 and sys.argv[8] else []

src = cairo.ImageSurface.create_from_png(frozen)
px, py = round(x * scale), round(y * scale)
pw = max(1, min(round(w * scale), src.get_width() - px))
ph = max(1, min(round(h * scale), src.get_height() - py))

dst = cairo.ImageSurface(cairo.FORMAT_ARGB32, pw, ph)
cr = cairo.Context(dst)
if points:
    for i, p in enumerate(points):
        lx, ly = (float(v) for v in p.split(","))
        (cr.move_to if i == 0 else cr.line_to)(lx * scale - px, ly * scale - py)
    cr.close_path()
    cr.clip()
cr.set_source_surface(src, -px, -py)
cr.paint()
dst.write_to_png(out)
