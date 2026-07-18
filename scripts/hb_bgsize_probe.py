#!/usr/bin/env python3
# scripts/hb_bgsize_probe.py — pixel-level asserts for CSS background-size,
# background-position and background-repeat in the hambrowse host gate. Reads the
# pixel backend's POSFILL geometry dump (one rect per block background box, in
# source order) plus the rendered P6 PPM, and checks that a wide (2:1) SOLID-RED
# image is placed/sized/tiled correctly inside each box, with the WHITE page
# background showing wherever the image does not reach:
#   * background-size: cover  -> the box is FULLY covered by red (no white);
#   * background-size: contain + no-repeat -> red fits inside preserving aspect,
#     leaving a WHITE letterbox strip on the trailing (right) edge;
#   * background-repeat: no-repeat + background-position: center -> a single red
#     block sits in the CENTRE, white in every corner;
#   * background-repeat: repeat-x -> a red band tiles across the TOP full width,
#     white below it.
# Placement is recomputed from the ACTUAL box size in POSFILL, so the gate does
# not depend on the exact layout width. Stdlib only (reuses ppm_to_png.read_ppm).
# Usage: hb_bgsize_probe.py <dump.txt> <render.ppm>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

NW, NH = 40, 20          # natural size of hb_bgsize_red.png
fails = []


def is_red(c):
    return c[0] > 180 and c[1] < 80 and c[2] < 80


def is_white(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200


def main():
    dump_path, ppm_path = sys.argv[1], sys.argv[2]
    dump = open(dump_path, "r", errors="replace").read().splitlines()
    w, h, pix = read_ppm(ppm_path)

    def px(x, y):
        if x < 0 or y < 0 or x >= w or y >= h:
            return (255, 255, 255)
        o = (y * w + x) * 3
        return (pix[o], pix[o + 1], pix[o + 2])

    boxes = []
    for ln in dump:
        t = ln.split()
        if not t or t[0] != "POSFILL":
            continue
        d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
        boxes.append((int(d["x0"]), int(d["y0"]), int(d["x1"]), int(d["y1"])))
    boxes.sort(key=lambda b: b[1])

    def ok(cond, msg):
        print(("[bgsz] PASS " if cond else "[bgsz] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    ok(len(boxes) == 4, "4 background-image boxes registered (got %d)"
       % len(boxes))
    if len(boxes) < 4:
        print("[bgsz] RESULT: FAIL")
        return 1

    cover, contain, center, repx = boxes
    # absolute-pixel sampler at box-relative (dx, dy)
    def at(box, dx, dy):
        return px(box[0] + dx, box[1] + dy)

    def bw(box):
        return box[2] - box[0]

    def bh(box):
        return box[3] - box[1]

    # ---- 1. cover: the whole box is red, no white shows through --------------
    cw, ch = bw(cover), bh(cover)
    allred = True
    for fx in (0.15, 0.5, 0.85):
        for fy in (0.15, 0.5, 0.85):
            c = at(cover, int(cw * fx), int(ch * fy))
            if not is_red(c):
                allred = False
    ok(allred, "cover fills the ENTIRE box with red (no page background)")

    # ---- 2. contain + no-repeat: red fits inside, white letterbox on right ---
    # min-scale = min(bw/NW, bh/NH); tile_w = NW*scale (as an integer ratio).
    cw, ch = bw(contain), bh(contain)
    # tile width in px = NW * min(bw/NW, bh/NH). Compare cross-products to pick.
    if cw * NH < ch * NW:
        tile_w = cw
    else:
        tile_w = NW * ch // NH
    inside = at(contain, max(2, tile_w // 3), ch // 2)      # within the image
    letter = at(contain, min(cw - 3, tile_w + (cw - tile_w) // 2), ch // 2)
    ok(is_red(inside), "contain: image area is red %s" % (inside,))
    ok(tile_w < cw - 4 and is_white(letter),
       "contain: WHITE letterbox on the trailing edge %s (tile_w=%d box_w=%d)"
       % (letter, tile_w, cw))

    # ---- 3. no-repeat + center: single red block centred, white corners ------
    cw, ch = bw(center), bh(center)
    ctr = at(center, cw // 2, ch // 2)
    c_tl = at(center, 3, 3)
    c_br = at(center, cw - 4, ch - 4)
    ok(is_red(ctr), "center: centre pixel is red %s" % (ctr,))
    ok(is_white(c_tl) and is_white(c_br),
       "center: corners show white page background (TL %s BR %s)"
       % (c_tl, c_br))

    # ---- 4. repeat-x: red band across the TOP full width, white below --------
    cw, ch = bw(repx), bh(repx)
    top_l = at(repx, cw // 4, NH // 2)
    top_r = at(repx, (cw * 3) // 4, NH // 2)
    below = at(repx, cw // 2, ch - 4)
    ok(is_red(top_l) and is_red(top_r),
       "repeat-x: red band tiles across the full top width (L %s R %s)"
       % (top_l, top_r))
    ok(is_white(below),
       "repeat-x: white below the single (un-tiled on Y) band %s" % (below,))

    if fails:
        print("[bgsz] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[bgsz] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
