#!/usr/bin/env python3
# scripts/hb_gradient2_probe.py — pixel-level asserts for the SECOND wave of CSS
# image backgrounds in the hambrowse host gate: conic-gradient, repeating-linear-
# gradient, and background-image: url(...) (a decoded raster background).
# Reads the pixel backend's POSFILL geometry dump (one rect per block background
# box, in source order) plus the rendered P6 PPM, and checks:
#   * conic-gradient(red, lime, blue): the colour varies BY ANGLE around the box
#     centre — red at 12 o'clock, green at 6 o'clock, yellow at 3 o'clock, teal
#     at 9 o'clock (four distinct hues, proving angular interpolation);
#   * repeating-linear-gradient(to right, red 0%, blue 25%): the red->blue ramp
#     TILES — the colour one 25% period apart repeats (x=0.05 ~= x=0.30), with a
#     bluish sample near a period end in between;
#   * background-image: url(hb_bgimg_tile.png): the 2x2 quadrant PNG shows its
#     DECODED pixels through the element background — red / green / blue / yellow
#     in the four quadrants (proving parse + store lookup + blit, not a gradient).
# Stdlib only (reuses ppm_to_png.read_ppm). Usage:
#   hb_gradient2_probe.py <dump.txt> <render.ppm>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []


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
        print(("[g2probe] PASS " if cond else "[g2probe] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    ok(len(boxes) == 3, "3 image-background boxes registered (got %d)"
       % len(boxes))
    if len(boxes) < 3:
        print("[g2probe] RESULT: FAIL")
        return 1

    conic, rep, bg = boxes[0], boxes[1], boxes[2]

    def samp(box, fx, fy):
        x0, y0, x1, y1 = box
        return px(x0 + int((x1 - x0) * fx), y0 + int((y1 - y0) * fy))

    # ---- 1. conic-gradient: colour varies by ANGLE around the centre ---------
    ct = samp(conic, 0.50, 0.20)   # 12 o'clock  -> red
    cb = samp(conic, 0.50, 0.80)   #  6 o'clock  -> green (lime)
    cl = samp(conic, 0.15, 0.50)   #  9 o'clock  -> teal (green<->blue mix)
    cr = samp(conic, 0.85, 0.50)   #  3 o'clock  -> yellow (red<->green mix)
    ok(ct[0] > 180 and ct[1] < 90, "conic TOP is reddish %s" % (ct,))
    ok(cb[1] > 180 and cb[0] < 90, "conic BOTTOM is greenish %s" % (cb,))
    ok(cr[0] > 80 and cr[1] > 80 and cr[2] < 80,
       "conic RIGHT is yellowish (R+G mid) %s" % (cr,))
    ok(cl[1] > 80 and cl[2] > 80 and cl[0] < 80,
       "conic LEFT is teal (G+B mid) %s" % (cl,))
    ok(ct != cb and cl != cr,
       "conic hue differs across the four angles (angular ramp)")

    # ---- 2. repeating-linear-gradient: the red->blue ramp TILES --------------
    p0 = samp(rep, 0.05, 0.70)     # start of a period -> reddish
    pm = samp(rep, 0.20, 0.70)     # near a period end  -> bluish
    p1 = samp(rep, 0.30, 0.70)     # +25% = one period later -> reddish again
    ok(p0[0] > 150 and p0[2] < 120, "repeat start-of-period is reddish %s"
       % (p0,))
    ok(pm[2] > 150 and pm[0] < 120, "repeat near-period-end is bluish %s"
       % (pm,))
    ok(p1[0] > 150 and p1[2] < 120,
       "repeat colour RECURS one period later (%s ~ %s) -> tiling" % (p1, p0))
    ok(abs(p1[0] - p0[0]) < 40 and abs(p1[2] - p0[2]) < 40,
       "repeat period colour matches across tiles")

    # ---- 3. background-image: url() -> decoded 2x2 quadrant PNG --------------
    tl = samp(bg, 0.30, 0.30)      # top-left     -> red
    tr = samp(bg, 0.70, 0.30)      # top-right    -> green
    bl = samp(bg, 0.30, 0.70)      # bottom-left  -> blue
    br = samp(bg, 0.70, 0.70)      # bottom-right -> yellow
    ok(tl[0] > 180 and tl[1] < 90 and tl[2] < 90,
       "bg-image TL shows RED image pixel %s" % (tl,))
    ok(tr[1] > 140 and tr[0] < 90 and tr[2] < 90,
       "bg-image TR shows GREEN image pixel %s" % (tr,))
    ok(bl[2] > 180 and bl[0] < 90 and bl[1] < 90,
       "bg-image BL shows BLUE image pixel %s" % (bl,))
    ok(br[0] > 180 and br[1] > 140 and br[2] < 90,
       "bg-image BR shows YELLOW image pixel %s" % (br,))

    if fails:
        print("[g2probe] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[g2probe] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
