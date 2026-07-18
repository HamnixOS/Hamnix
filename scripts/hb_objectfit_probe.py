#!/usr/bin/env python3
# scripts/hb_objectfit_probe.py — pixel-level asserts for CSS replaced-element
# sizing in the hambrowse host gate: object-fit, object-position, aspect-ratio
# and text-overflow:ellipsis. Reads the pixel backend's geometry dump (IMGSEG
# lines: one per <img> box, giving slot/w/h/x/top; POSFILL lines: one per block
# background box; SEGTXT lines: the painted text runs) plus the rendered P6 PPM.
#
# The test image hb_objfit.png is 40x20 (2:1): LEFT half GREEN, RIGHT half RED.
# Page background is WHITE, so a contain letterbox reads as white.
#   * object-fit:cover  on a 40x40 box -> box FULLY covered (no white bars);
#   * object-fit:contain on a 40x40 box -> a horizontal band, WHITE letterbox
#     top and bottom (the 2:1 image fits the width, leaving vertical bars);
#   * object-fit:none + object-position:left top  on 20x20 -> top-left of the
#     image (GREEN) shows;
#   * object-fit:none + object-position:right top on 20x20 -> top-right (RED);
#   * .ar: width:200 + aspect-ratio:2/1 -> the background box lays out ~100px
#     tall (6 rows at LINE_H=16), NOT the ~1-row content height;
#   * .ell: overflow:hidden;white-space:nowrap;text-overflow:ellipsis -> the long
#     word is truncated and ends with "..." (the ellipsis rendered by the engine).
# Stdlib only (reuses ppm_to_png.read_ppm). Usage: probe <dump.txt> <render.ppm>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []


def is_red(c):
    return c[0] > 150 and c[1] < 90 and c[2] < 90


def is_green(c):
    return c[1] > 130 and c[0] < 120 and c[2] < 120


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

    imgs = []          # (w, h, x, top) in source order
    fills = {}         # col -> (x0, y0, x1, y1)
    segtxt = []
    for ln in dump:
        t = ln.split()
        if not t:
            continue
        if t[0] == "IMGSEG":
            d = {t[i]: t[i + 1] for i in range(1, len(t) - 1, 2)}
            imgs.append((int(d["w"]), int(d["h"]), int(d["x"]), int(d["top"])))
        elif t[0] == "POSFILL":
            d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
            col = d.get("col", "")
            fills[col] = (int(d["x0"]), int(d["y0"]), int(d["x1"]), int(d["y1"]))
        elif t[0] == "SEGTXT":
            segtxt.append(ln[len("SEGTXT "):])

    def ok(cond, msg):
        print(("[objfit] PASS " if cond else "[objfit] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    ok(len(imgs) >= 4, "4 <img> boxes registered (got %d)" % len(imgs))
    if len(imgs) < 4:
        print("[objfit] RESULT: FAIL")
        return 1

    cover, contain, noleft, noright = imgs[0], imgs[1], imgs[2], imgs[3]

    def center(box):
        bw, bh, bx, by = box
        return px(bx + bw // 2, by + bh // 2)

    # ---- 1. cover: whole box covered (no white anywhere inside) --------------
    bw, bh, bx, by = cover
    anywhite = False
    for fx in (0.15, 0.5, 0.85):
        for fy in (0.15, 0.5, 0.85):
            if is_white(px(bx + int(bw * fx), by + int(bh * fy))):
                anywhite = True
    ok(not anywhite, "cover: box fully covered by the image (no white bars)")

    # ---- 2. contain: white letterbox top and bottom, image band in middle ----
    bw, bh, bx, by = contain
    top_c = px(bx + bw // 2, by + 2)
    mid_c = px(bx + bw // 2, by + bh // 2)
    bot_c = px(bx + bw // 2, by + bh - 3)
    ok(is_white(top_c) and is_white(bot_c),
       "contain: WHITE letterbox bars top %s + bottom %s" % (top_c, bot_c))
    ok(is_red(mid_c) or is_green(mid_c),
       "contain: image band fills the middle %s" % (mid_c,))

    # ---- 3. object-fit:none + object-position keywords -----------------------
    cl = center(noleft)
    cr = center(noright)
    ok(is_green(cl), "object-position:left top -> shows the image's GREEN left "
       "half %s" % (cl,))
    ok(is_red(cr), "object-position:right top -> shows the image's RED right "
       "half %s" % (cr,))

    # ---- 4. aspect-ratio: the .ar (aspect 2/1) box lays out to the SAME height
    # as the .arref (explicit height:100px) box of equal width. Both derive from
    # a 100px CSS height, so equal pixel spans prove aspect-ratio computed 100px.
    ar = fills.get("#c00000")        # .ar   width:200 aspect-ratio:2/1
    arref = fills.get("#00a000")     # .arref width:200 height:100px
    ok(ar is not None and arref is not None,
       "aspect-ratio: found both the .ar and .arref (height:100) boxes")
    if ar is not None and arref is not None:
        arh = ar[3] - ar[1]
        refh = arref[3] - arref[1]
        arw = ar[2] - ar[0]
        ok(abs(arh - refh) <= 2,
           "aspect-ratio:2/1 + width:200 lays out to the height:100px reference "
           "height (aspect=%dpx, ref=%dpx)" % (arh, refh))
        ok(arh > 40 and arw >= 150,
           "aspect-ratio box is a tall ~200px-wide block, not the content "
           "height (h=%d w=%d)" % (arh, arw))

    # ---- 5. text-overflow:ellipsis: a truncated run ends with "..." ----------
    ell = [s for s in segtxt if s.endswith("...")]
    ok(len(ell) >= 1,
       "ellipsis: a painted text run is truncated with a trailing ellipsis "
       "(...): %s" % (ell[:1],))
    # and the full long word did NOT survive intact (it was clipped).
    intact = [s for s in segtxt if "EXPIALIDOCIOUS" in s]
    ok(len(intact) == 0,
       "ellipsis: the overflowing text was clipped (no intact long word)")

    if fails:
        print("[objfit] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[objfit] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
