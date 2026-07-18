#!/usr/bin/env python3
"""scripts/hb_flexbg_probe.py — flex/grid container-background PNG-truth probe.

Reads the binary P6 PPM the REAL pixel backend (user/hambrowse_host_gfx.ad ->
lib/htmlpage + lib/htmlpaint) writes and LOOKS at the framebuffer to prove a
`display:flex`/`display:grid` container paints its own background box BEHIND its
items (the on-device "flex nav renders its links but not its background band"
defect). For each queried RRGGBB colour it reports the pixel count and bounding
box; the calling gate asserts the container band AND the item chips are BOTH
present (container behind, chips on top) and, optionally, that a sampled point
carries the container colour rather than page white.

Stdlib only (no PIL): the same P6 reader as scripts/ppm_to_png.py.

USAGE
  hb_flexbg_probe.py FILE.ppm RRGGBB[,RRGGBB...]        # counts + bboxes
  hb_flexbg_probe.py FILE.ppm --at X Y                  # colour at a pixel

Prints one `FOUND`/`MISS` line per colour (exit status always 0).
"""
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


def _rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def main():
    a = sys.argv
    ppm = a[1]
    w, h, pix = read_ppm(ppm)
    if len(a) > 2 and a[2] == "--at":
        x, y = int(a[3]), int(a[4])
        o = (y * w + x) * 3
        print("AT %d %d #%02x%02x%02x" % (x, y, pix[o], pix[o + 1], pix[o + 2]))
        return
    tol = 10
    for hexc in a[2].split(","):
        tr, tg, tb = _rgb(hexc)
        n = 0
        x0 = y0 = 1 << 30
        x1 = y1 = -1
        for y in range(h):
            row = y * w * 3
            for x in range(w):
                o = row + x * 3
                if abs(pix[o] - tr) <= tol and abs(pix[o + 1] - tg) <= tol \
                        and abs(pix[o + 2] - tb) <= tol:
                    n += 1
                    if x < x0:
                        x0 = x
                    if x > x1:
                        x1 = x
                    if y < y0:
                        y0 = y
                    if y > y1:
                        y1 = y
        if n > 0:
            print("FOUND #%s n=%d x=%d y=%d w=%d h=%d"
                  % (hexc.lstrip("#"), n, x0, y0, x1 - x0 + 1, y1 - y0 + 1))
        else:
            print("MISS  #%s" % hexc.lstrip("#"))


if __name__ == "__main__":
    main()
