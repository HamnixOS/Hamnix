#!/usr/bin/env python3
# scripts/hb_canvas_probe.py — pixel-assert the Canvas 2D core render.
#
# A visual gate can false-green, so this samples the ACTUAL framebuffer pixels of
# the rendered page (a binary P6 PPM) and checks that each Canvas 2D primitive
# landed the expected colour at the expected page-relative coordinate. The
# canvas draws in canvas-LOCAL coordinates; the <canvas> box is composited into
# the page at (XOFF, TOP), so every sample point is (XOFF+localx, TOP+localy).
#
# Usage: hb_canvas_probe.py PPM XOFF TOP
# Exits 0 iff every assertion passes.
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
        print("usage: hb_canvas_probe.py PPM XOFF TOP", file=sys.stderr)
        return 2
    ppm, xoff, top = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    w, h, pix = read_ppm(ppm)

    def px(lx, ly):
        x, y = xoff + lx, top + ly
        if x < 0 or y < 0 or x >= w or y >= h:
            return None
        o = (y * w + x) * 3
        return "#%02x%02x%02x" % (pix[o], pix[o + 1], pix[o + 2])

    fails = 0

    def col(lx, ly, want, msg):
        nonlocal fails
        got = px(lx, ly)
        if got == want:
            print("[hb-canvas2d] PASS %s ((%d,%d)=%s)" % (msg, lx, ly, got))
        else:
            print("[hb-canvas2d] FAIL %s ((%d,%d)=%s, want %s)" %
                  (msg, lx, ly, got, want))
            fails += 1

    def ink(x0, y0, x1, y1, msg):
        # any non-white pixel in the local box counts as ink (text is AA, so an
        # exact glyph-pixel colour is not stable — presence of ink is).
        nonlocal fails
        for ly in range(y0, y1):
            for lx in range(x0, x1):
                g = px(lx, ly)
                if g is not None and g != "#ffffff":
                    print("[hb-canvas2d] PASS %s (ink at (%d,%d)=%s)" %
                          (msg, lx, ly, g))
                    return
        print("[hb-canvas2d] FAIL %s (no ink in box)" % msg)
        fails += 1

    # background: an untouched canvas cell is the opaque white we filled.
    col(5, 140, "#ffffff", "white page-cover fillRect")
    # a red fillRect square, exact fillStyle colour.
    col(35, 35, "#ff0000", "red fillRect square")
    # blue strokeRect: solid ink on the top edge, hollow interior.
    col(90, 20, "#0000ff", "blue strokeRect edge")
    col(90, 40, "#ffffff", "strokeRect interior is hollow")
    # green filled triangle interior.
    col(160, 30, "#008000", "green path-fill triangle")
    # purple rect() path fill interior.
    col(30, 125, "#800080", "purple rect() path fill")
    # text: AA ink somewhere in the 'Hi' glyph box (baseline y=100).
    ink(20, 86, 40, 101, "fillText drew glyph ink")
    # drawImage: sprite scaled 20x20 -> 40x40 at (100,90). Cyan marker region
    # and magenta body must land at their scaled dest coordinates.
    col(110, 100, "#00ffff", "drawImage cyan marker (scaled)")
    col(130, 122, "#ff00ff", "drawImage magenta body (scaled)")
    # just outside the sprite dest rect stays white.
    col(150, 100, "#ffffff", "drawImage clipped to dest rect")

    if fails == 0:
        print("[hb-canvas2d] ALL PASS")
        return 0
    print("[hb-canvas2d] %d FAILURE(S)" % fails)
    return 1


if __name__ == "__main__":
    sys.exit(main())
