#!/usr/bin/env python3
# scripts/hb_borderradius_probe.py — pixel-level corner-cut asserts for the
# hambrowse CSS border-radius host gate. Proves that a large border-radius on a
# solid-colour box ACTUALLY cuts the corners: the four corner pixels show the
# page background (the fill does NOT reach them) while the box CENTRE and the
# four edge midpoints ARE the fill colour (the straight edges are not eroded).
#
# Reads the pixel backend's POSFILL geometry dump (one rect per block background
# box: "POSFILL <i> z <z> x0 <x0> y0 <y0> x1 <x1> y1 <y1> col #hex pix #hex")
# plus the rendered P6 PPM. The big-radius box is the one whose fill colour is
# the distinctive #0040ff. Stdlib only. Usage:
#   hb_borderradius_probe.py <dump.txt> <render.ppm>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []
TARGET = (0x00, 0x40, 0xff)   # .bigrad fill colour
PAGE = (255, 255, 255)        # default page background


def near(a, b, tol=24):
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def main():
    dump_path, ppm_path = sys.argv[1], sys.argv[2]
    dump = open(dump_path, "r", errors="replace").read().splitlines()
    w, h, pix = read_ppm(ppm_path)

    def px(x, y):
        if x < 0 or y < 0 or x >= w or y >= h:
            return PAGE
        o = (y * w + x) * 3
        return (pix[o], pix[o + 1], pix[o + 2])

    box = None
    for ln in dump:
        t = ln.split()
        if not t or t[0] != "POSFILL":
            continue
        d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
        col = d.get("col", "").lstrip("#").lower()
        if col == "0040ff":
            box = (int(d["x0"]), int(d["y0"]), int(d["x1"]), int(d["y1"]))
    if box is None:
        print("[brprobe] FAIL: #0040ff big-radius box not found in dump")
        print("[brprobe] RESULT: FAIL")
        return 1

    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    print("[brprobe] bigrad box x0=%d y0=%d x1=%d y1=%d (%dx%d)"
          % (x0, y0, x1, y1, x1 - x0, y1 - y0))

    def ok(cond, msg):
        print(("[brprobe] PASS " if cond else "[brprobe] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    # 1. The four CORNERS are CUT — they show the page background, not the fill.
    #    Sample 1px inside each corner (the arc removes a ~radius-sized wedge).
    corners = {
        "top-left": px(x0 + 1, y0 + 1),
        "top-right": px(x1 - 2, y0 + 1),
        "bottom-left": px(x0 + 1, y1 - 2),
        "bottom-right": px(x1 - 2, y1 - 2),
    }
    for name, c in corners.items():
        ok(near(c, PAGE) and not near(c, TARGET),
           "%s corner is page bg (cut), not fill  got rgb%s" % (name, c))

    # 2. The box CENTRE is the fill colour (interior painted).
    ok(near(px(cx, cy), TARGET),
       "box centre is the #0040ff fill  got rgb%s" % (px(cx, cy),))

    # 3. The four EDGE MIDPOINTS are the fill colour (straight edges kept — the
    #    rounding only eats the corners, not the middle of each side).
    edges = {
        "left-mid": px(x0 + 1, cy),
        "right-mid": px(x1 - 2, cy),
        "top-mid": px(cx, y0),
        "bottom-mid": px(cx, y1 - 1),
    }
    for name, c in edges.items():
        ok(near(c, TARGET),
           "%s edge midpoint is the #0040ff fill  got rgb%s" % (name, c))

    if fails:
        print("[brprobe] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[brprobe] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
