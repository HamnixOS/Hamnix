#!/usr/bin/env python3
# scripts/hb_gradient_probe.py — pixel-level asserts for the hambrowse CSS
# gradient-background host gate. Reads the pixel backend's POSFILL geometry dump
# (one rect per block background box, in source order) plus the rendered P6 PPM,
# and checks that each gradient box interpolates correctly across its axis:
#   * linear-gradient(to right, red, blue): left reddish, middle purple, right
#     bluish (colour varies HORIZONTALLY, constant down each column);
#   * linear-gradient(to bottom, #0f0, #000): top green, bottom near-black
#     (colour varies VERTICALLY, constant across each row);
#   * linear-gradient(135deg, red, yellow): red at top-left, yellow at
#     bottom-right (a real diagonal — green channel rises both L->R and T->B);
#   * a 3-stop linear-gradient(to right, red, lime, blue): lime in the MIDDLE;
#   * radial-gradient(circle, white, black): white centre, black corners.
# Stdlib only (reuses ppm_to_png.read_ppm). Usage:
#   hb_gradient_probe.py <dump.txt> <render.ppm>
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

    # POSFILL lines carry "x0 <> y0 <> x1 <> y1 <>" — collect in source order.
    boxes = []
    for ln in dump:
        t = ln.split()
        if not t or t[0] != "POSFILL":
            continue
        d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
        boxes.append((int(d["x0"]), int(d["y0"]), int(d["x1"]), int(d["y1"])))
    boxes.sort(key=lambda b: b[1])

    def ok(cond, msg):
        print(("[gprobe] PASS " if cond else "[gprobe] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    ok(len(boxes) == 5, "5 gradient background boxes registered (got %d)"
       % len(boxes))
    if len(boxes) < 5:
        print("[gprobe] RESULT: FAIL")
        return 1

    hgrad, vgrad, diag, three, rad = boxes[0], boxes[1], boxes[2], boxes[3], \
        boxes[4]

    # The single text row sits at the TOP of each box; the rest of the box is
    # pure gradient. So sample the LOWER portion (fy >= ~0.45) for reads that
    # must be clear of glyph ink, and use the RIGHT edge for the top of the
    # vertical gradient (the short left-aligned label never reaches it).
    def samp(box, fx, fy):
        x0, y0, x1, y1 = box
        x = x0 + int((x1 - x0) * fx)
        y = y0 + int((y1 - y0) * fy)
        return px(x, y)

    # ---- 1. to right, red -> blue: left red, middle purple, right blue -------
    # Colour varies horizontally only, so read the clean lower band.
    L = samp(hgrad, 0.02, 0.70)
    M = samp(hgrad, 0.50, 0.70)
    R = samp(hgrad, 0.98, 0.70)
    ok(L[0] > 180 and L[2] < 70, "hgrad LEFT is reddish %s" % (L,))
    ok(R[2] > 180 and R[0] < 70, "hgrad RIGHT is bluish %s" % (R,))
    ok(80 < M[0] < 180 and 80 < M[2] < 180,
       "hgrad MIDDLE is purple (both R and B mid) %s" % (M,))
    # constant DOWN a column: two rows in the same column read the same colour.
    Lb = samp(hgrad, 0.02, 0.92)
    ok(abs(L[0] - Lb[0]) < 20 and abs(L[2] - Lb[2]) < 20,
       "hgrad colour is constant DOWN a column (%s ~ %s)" % (L, Lb))

    # ---- 2. to bottom, green -> black: top green, bottom near-black ----------
    # Colour varies vertically only; read the right edge (clear of the label).
    T = samp(vgrad, 0.95, 0.05)
    B = samp(vgrad, 0.95, 0.95)
    ok(T[1] > 180 and T[0] < 70, "vgrad TOP is green %s" % (T,))
    ok(B[1] < 70, "vgrad BOTTOM is near-black %s" % (B,))
    # constant ACROSS a row: two columns of the clean bottom row read the same.
    Bl = samp(vgrad, 0.15, 0.95)
    ok(abs(B[1] - Bl[1]) < 20,
       "vgrad colour is constant ACROSS a row (%s ~ %s)" % (B, Bl))

    # ---- 3. 135deg, red -> yellow: green channel rises L->R AND T->B ---------
    # All three probes sit in the clean lower half (below the label row).
    BR = samp(diag, 0.97, 0.90)
    BL = samp(diag, 0.03, 0.90)
    ML = samp(diag, 0.03, 0.48)
    ok(BR[0] > 180 and BR[1] > 180 and BR[2] < 90,
       "diag BOTTOM-RIGHT is yellow %s" % (BR,))
    ok(BL[0] > 180, "diag BOTTOM-LEFT keeps red channel %s" % (BL,))
    ok(BR[1] > BL[1] + 50,
       "diag green rises L->R along a row (BL g=%d -> BR g=%d)"
       % (BL[1], BR[1]))
    # The vertical rise is genuinely small: the box is far wider than it is
    # tall (~600x94), so the diagonal axis is width-dominated. A rise > 8 still
    # proves a TRUE diagonal — a pure to-right gradient would give exactly 0.
    ok(BL[1] > ML[1] + 8,
       "diag green rises T->B down a column (ML g=%d -> BL g=%d)"
       % (ML[1], BL[1]))

    # ---- 4. 3-stop red/lime/blue: lime in the middle -------------------------
    C = samp(three, 0.50, 0.70)
    ok(C[1] > 180 and C[0] < 90 and C[2] < 90,
       "three-stop MIDDLE stop is lime %s" % (C,))

    # ---- 5. radial white -> black: white centre, dark corners ----------------
    ctr = samp(rad, 0.50, 0.55)
    cor = samp(rad, 0.02, 0.92)
    ok(ctr[0] > 200 and ctr[1] > 200 and ctr[2] > 200,
       "radial CENTRE is white %s" % (ctr,))
    ok(cor[0] < 90, "radial CORNER is dark %s" % (cor,))

    if fails:
        print("[gprobe] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[gprobe] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
