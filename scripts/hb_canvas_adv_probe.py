#!/usr/bin/env python3
# scripts/hb_canvas_adv_probe.py — pixel-assert the advanced Canvas 2D render
# (gradients, transforms, save/restore isolation, getImageData/putImageData).
#
# The canvas draws in canvas-LOCAL coordinates; its <canvas> box composites into
# the page at (XOFF, TOP), so each sample is (XOFF+localx, TOP+localy). Solid
# fills are asserted exactly; gradient interpolation is asserted with channel
# inequalities (a start pixel skews to stop0, an end pixel to stop1, the midpoint
# blends both) since exact sub-pixel values are not the point.
#
# Usage: hb_canvas_adv_probe.py PPM XOFF TOP
import sys


def read_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise ValueError("not a P6 PPM")
    idx = 2
    vals = []
    while len(vals) < 3:
        while idx < len(data) and data[idx] in b" \t\n\r":
            idx += 1
        if idx < len(data) and data[idx:idx + 1] == b"#":
            while idx < len(data) and data[idx] not in b"\n":
                idx += 1
            continue
        s = idx
        while idx < len(data) and data[idx] not in b" \t\n\r":
            idx += 1
        vals.append(int(data[s:idx]))
    w, h, _maxv = vals
    idx += 1
    return w, h, data[idx:idx + w * h * 3]


def main():
    if len(sys.argv) != 4:
        print("usage: hb_canvas_adv_probe.py PPM XOFF TOP", file=sys.stderr)
        return 2
    ppm, xoff, top = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    w, h, pix = read_ppm(ppm)
    fails = 0

    def rgb(lx, ly):
        x, y = xoff + lx, top + ly
        if x < 0 or y < 0 or x >= w or y >= h:
            return None
        o = (y * w + x) * 3
        return (pix[o], pix[o + 1], pix[o + 2])

    def hexs(t):
        return None if t is None else "#%02x%02x%02x" % t

    def col(lx, ly, want, msg):
        nonlocal fails
        got = hexs(rgb(lx, ly))
        if got == want:
            print("[hb-adv] PASS %s ((%d,%d)=%s)" % (msg, lx, ly, got))
        else:
            print("[hb-adv] FAIL %s ((%d,%d)=%s, want %s)" %
                  (msg, lx, ly, got, want))
            fails += 1

    def check(lx, ly, ok, want, msg):
        nonlocal fails
        t = rgb(lx, ly)
        if t is not None and ok(t):
            print("[hb-adv] PASS %s ((%d,%d)=%s)" % (msg, lx, ly, hexs(t)))
        else:
            print("[hb-adv] FAIL %s ((%d,%d)=%s, want %s)" %
                  (msg, lx, ly, hexs(t), want))
            fails += 1

    # ---- (1) LINEAR gradient red(#ff0000)->blue(#0000ff), x in [10,110] ----
    check(12, 30, lambda t: t[0] > 200 and t[2] < 60, "r>>b (near stop0)",
          "linear gradient start ~= red")
    check(108, 30, lambda t: t[2] > 200 and t[0] < 60, "b>>r (near stop1)",
          "linear gradient end ~= blue")
    check(60, 30, lambda t: 60 < t[0] < 200 and 60 < t[2] < 200 and t[1] < 60,
          "r and b both mid, g low", "linear gradient midpoint blended")

    # ---- (2) TRANSFORM translate+rotate: green rect device quad x[138,150] ----
    col(144, 110, "#00aa00", "translate+rotate green rect landed")
    # the UNtransformed (0,0,40,12) location must stay white (proves the CTM
    # actually moved the rect, not an identity draw).
    col(20, 6, "#ffffff", "transform not applied at untransformed origin")

    # ---- (3) SAVE/RESTORE isolation: orange lands at literal (10,120) ----
    col(20, 125, "#ff8800", "orange rect after restore at identity position")
    # ...and no green leaked here (transform was popped).
    check(20, 125, lambda t: t == (255, 136, 0), "still orange",
          "restore popped the rotate transform")

    # ---- (4) RADIAL gradient yellow center -> purple edge, ctr (200,40) ----
    check(200, 40, lambda t: t[0] > 200 and t[1] > 200 and t[2] < 80,
          "yellow-ish center", "radial gradient center ~= yellow")
    check(200, 67, lambda t: t[2] > 60 and t[1] < 150 and t[0] < 230,
          "purple-ish edge", "radial gradient edge ~= purple")

    # ---- (5) getImageData/putImageData round trip ----
    col(68, 128, "#00ffff", "source cyan block drawn")
    col(108, 128, "#00ffff", "putImageData copied cyan block to (100,120)")
    col(148, 128, "#ff00ff", "createImageData+putImageData magenta block")

    if fails == 0:
        print("[hb-adv] ALL PASS")
        return 0
    print("[hb-adv] %d FAILURE(S)" % fails)
    return 1


if __name__ == "__main__":
    sys.exit(main())
