#!/usr/bin/env python3
# scripts/hb_transform_probe.py — pixel-level asserts for the hambrowse CSS 2D
# `transform` host gate. Reads the pixel backend's POSFILL geometry dump (the
# UNTRANSFORMED block-background rects, in source order — the engine records
# layout geometry; the transform is applied only at paint time) plus the
# rendered P6 PPM, and checks that each box's coloured region has MOVED / SCALED
# / ROTATED to the expected place while its vacated origin shows the page
# background:
#   box 0  transform: translate(50px,30px)   -> region shifts +50,+30 exactly
#   box 1  transform: scale(2)               -> region doubles about its centre
#   box 2  transform: rotate(90deg) (WIDE)   -> wide box becomes TALL
#   box 3  transform: matrix(1,0,0,1,50,30)  -> identical to translate(50,30)
# Stdlib only (reuses ppm_to_png.read_ppm). Usage:
#   hb_transform_probe.py <dump.txt> <render.ppm>
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []


def main():
    dump_path, ppm_path = sys.argv[1], sys.argv[2]
    dump = open(dump_path, "r", errors="replace").read().splitlines()
    w, h, pix = read_ppm(ppm_path)

    def px(x, y):
        x = int(round(x))
        y = int(round(y))
        if x < 0 or y < 0 or x >= w or y >= h:
            return (255, 255, 255)
        o = (y * w + x) * 3
        return (pix[o], pix[o + 1], pix[o + 2])

    def near(a, b, tol=40):
        return all(abs(a[i] - b[i]) <= tol for i in range(3))

    def is_bg(c):        # page background is white
        return near(c, (255, 255, 255), 30)

    # POSFILL lines carry "x0 <> y0 <> x1 <> y1 <>" (the untransformed rects).
    boxes = []
    for ln in dump:
        t = ln.split()
        if not t or t[0] != "POSFILL":
            continue
        d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
        boxes.append((int(d["x0"]), int(d["y0"]), int(d["x1"]), int(d["y1"])))
    boxes.sort(key=lambda b: b[1])

    def ok(cond, msg):
        print(("[xprobe] PASS " if cond else "[xprobe] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    ok(len(boxes) == 4, "4 transformed background boxes registered (got %d)"
       % len(boxes))
    if len(boxes) < 4:
        print("[xprobe] RESULT: FAIL")
        return 1

    RED, GREEN, BLUE, MAG = (255, 0, 0), (0, 204, 0), (0, 0, 255), (204, 0, 204)

    # ---- box 0: translate(50px, 30px) ----
    x0, y0, x1, y1 = boxes[0]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    ok(near(px(cx + 50, cy + 30), RED),
       "translate: centre moved +50,+30 is red (%s)" % (px(cx + 50, cy + 30),))
    ok(near(px(x0 + 6 + 50, y1 - 6 + 30), RED),
       "translate: bottom-left corner shifted +50,+30 is red")
    ok(is_bg(px(x0 + 6, cy)),
       "translate: original left edge vacated to background (%s)"
       % (px(x0 + 6, cy),))

    # ---- box 1: scale(2) about centre ----
    x0, y0, x1, y1 = boxes[1]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    bw, bh = x1 - x0, y1 - y0
    ok(near(px(cx, cy), GREEN), "scale2: centre is green")
    # a point just OUTSIDE the original left edge but INSIDE the 2x box.
    ox = x0 - bw * 0.3
    ok(near(px(ox, cy), GREEN),
       "scale2: expanded past original left edge is green (x=%d)" % int(ox))
    oy = y0 - bh * 0.3
    ok(near(px(cx, oy), GREEN),
       "scale2: expanded past original top edge is green (y=%d)" % int(oy))
    # far beyond the doubled box (1.2*half-width from centre) is background.
    ok(is_bg(px(cx + bw * 1.2, cy)),
       "scale2: far outside the doubled box is background")

    # ---- box 2: rotate(90deg) on a WIDE box -> becomes TALL ----
    x0, y0, x1, y1 = boxes[2]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    bw, bh = x1 - x0, y1 - y0     # wide: bw >> bh
    ok(bw > bh, "rotate90: source box is wider than tall (%dx%d)" % (bw, bh))
    ok(near(px(cx, cy), BLUE), "rotate90: centre is blue")
    # The rotated box is bh wide x bw tall. Sample ABOVE the original top edge
    # (within the new tall extent) -> must be blue (proves it grew vertically).
    ty = cy - bw * 0.35
    ok(near(px(cx, ty), BLUE),
       "rotate90: extends well above original top -> tall (y=%d is blue)"
       % int(ty))
    ok(near(px(cx, cy + bw * 0.35), BLUE),
       "rotate90: extends well below original bottom -> tall")
    # Sample near the original left/right extremes -> now OUTSIDE the narrow
    # rotated box -> background (proves it lost its width).
    ok(is_bg(px(x0 + bw * 0.08, cy)),
       "rotate90: original left extreme vacated -> narrow (%s)"
       % (px(x0 + bw * 0.08, cy),))
    ok(is_bg(px(x1 - bw * 0.08, cy)),
       "rotate90: original right extreme vacated -> narrow")

    # ---- box 3: matrix(1,0,0,1,50,30) == translate(50,30) ----
    x0, y0, x1, y1 = boxes[3]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    ok(near(px(cx + 50, cy + 30), MAG),
       "matrix: centre moved +50,+30 is magenta (matrix==translate)")
    ok(is_bg(px(x0 + 6, cy)),
       "matrix: original left edge vacated to background")

    if fails:
        print("[xprobe] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[xprobe] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
