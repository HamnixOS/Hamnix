#!/usr/bin/env python3
# scripts/hb_boxshadow_probe.py — pixel-level asserts for the hambrowse
# box-shadow + opacity/rgba-alpha host gate. Reads the pixel backend's POSFILL
# geometry dump (block-fill rects + an interior sampled pixel) plus the rendered
# P6 PPM, and checks that:
#   * an opacity:.5 solid box composites to the 50% blend (NOT the opaque colour)
#   * an rgba(255,0,0,.5) fill reads PINK over white (NOT pure red)
#   * a box-shadow paints a dark, fading grey drop shadow offset DOWN/RIGHT of
#     the card, on the white paper around it.
# Stdlib only (reuses ppm_to_png.read_ppm). Usage:
#   hb_boxshadow_probe.py <dump.txt> <render.ppm>
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []


def near(a, b, tol):
    return abs(a - b) <= tol


def main():
    dump_path, ppm_path = sys.argv[1], sys.argv[2]
    dump = open(dump_path, "r", errors="replace").read().splitlines()
    w, h, pix = read_ppm(ppm_path)

    def px(x, y):
        if x < 0 or y < 0 or x >= w or y >= h:
            return (255, 255, 255)
        o = (y * w + x) * 3
        return (pix[o], pix[o + 1], pix[o + 2])

    # index POSFILL rects by declared colour.
    fills = {}
    for ln in dump:
        t = ln.split()
        if not t or t[0] != "POSFILL":
            continue
        d = {t[i]: t[i + 1] for i in range(2, len(t) - 1, 2)}
        d["idx"] = t[1]
        fills[d["col"]] = d

    def hexpix(s):
        s = s.lstrip("#")
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))

    def ok(cond, msg):
        print(("[probe] PASS " if cond else "[probe] FAIL ") + msg)
        if not cond:
            fails.append(msg)

    # ---- 1. opacity:.5 on #3060c0 -> 50% blend over white (periwinkle) --------
    f = fills.get("#3060c0")
    ok(f is not None, "opacity box (#3060c0) fill present")
    if f:
        r, g, b = hexpix(f["pix"])
        # opaque would be (48,96,192); the 50% blend over white is ~(155,178,225)
        ok(near(r, 155, 20) and near(g, 178, 20) and near(b, 225, 20),
           "opacity:.5 blends to ~(155,178,225), got (%d,%d,%d)" % (r, g, b))
        ok(r > 110, "opacity box is NOT opaque (r=%d, opaque would be 48)" % r)

    # ---- 2. rgba(255,0,0,.5) over white -> pink, not red ----------------------
    f = fills.get("#ff0000")
    ok(f is not None, "rgba box (#ff0000) fill present")
    if f:
        r, g, b = hexpix(f["pix"])
        ok(r > 230 and near(g, 132, 24) and near(b, 132, 24),
           "rgba(255,0,0,.5) blends to PINK ~(255,132,132), got (%d,%d,%d)"
           % (r, g, b))
        ok(g > 80 and b > 80,
           "rgba box is NOT pure red (g=%d b=%d, opaque red would be 0)" % (g, b))

    # ---- 3. box-shadow: dark fading grey offset down/right of the card --------
    f = fills.get("#dfe6f5")
    ok(f is not None, "shadow card (#dfe6f5) fill present")
    if f:
        x0, y0 = int(f["x0"]), int(f["y0"])
        x1, y1 = int(f["x1"]), int(f["y1"])
        ymid = (y0 + y1) // 2
        xmid = (x0 + x1) // 2

        def is_grey(p, ceil=250):
            r, g, b = p
            return r == g == b and r < ceil

        # near-edge shadow (right + below) is a dark grey; further out fades white
        right_near = px(x1 + 1, ymid)
        right_far = px(x1 + 14, ymid)
        below_near = px(xmid, y1 + 1)
        below_far = px(xmid, y1 + 14)
        ok(is_grey(right_near, 240),
           "shadow present RIGHT of card, dark grey %s" % (right_near,))
        ok(is_grey(below_near, 240),
           "shadow present BELOW card, dark grey %s" % (below_near,))
        ok(right_far[0] > right_near[0] and below_far[0] > below_near[0],
           "shadow FADES outward (near %d/%d darker than far %d/%d)"
           % (right_near[0], below_near[0], right_far[0], below_far[0]))
        # offset: the down/right shadow is denser (darker) than up/left.
        up_near = px(xmid, y0 - 1)
        left_near = px(x0 - 1, ymid)
        ok(below_near[0] < up_near[0] and right_near[0] < left_near[0],
           "shadow OFFSET down/right (down %d<up %d, right %d<left %d)"
           % (below_near[0], up_near[0], right_near[0], left_near[0]))
        # sanity: white paper well clear of the card stays white.
        ok(px(x1 + 60, ymid) == (255, 255, 255),
           "paper clear of the shadow stays white")

    if fails:
        print("[probe] RESULT: FAIL (%d)" % len(fails))
        return 1
    print("[probe] RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
