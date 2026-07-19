#!/usr/bin/env python3
"""scripts/hb_rangeprog_probe.py — pixel probe for CSS `accent-color` on
<input type=range> and <progress> in the native browser's real pixel painter
(lib/htmlpage + lib/htmlpaint).

Reads a P6 PPM (rendered by user/hambrowse_host_gfx.ad). Each range/progress is
drawn as a thin horizontal bar: a light-grey track with the value fraction filled
in the accent-colour. This probe scans each scanline for the longest run of a
SATURATED colour (the accent fill), clusters the ink into vertical bands (one per
control, top-to-bottom) and reports per band:

  BAR i=<n> y=<top> fill=<#rrggbb> runw=<pixels>

  * fill: the dominant saturated colour of the band's widest coloured run — the
    accent fill. This proves accent-color took effect (red/green/orange vs the UA
    default blue rgb(26,115,232)).
  * runw: the width in px of that coloured run — proportional to the value
    fraction (a value=100 range fills the whole ~90px track; value=50 fills ~half).

Exit status is always 0; the calling gate parses these lines and asserts.

USAGE
  hb_rangeprog_probe.py FILE.ppm
"""
import sys


def _read_ppm(path):
    f = open(path, "rb")
    magic = f.readline().strip()
    if magic != b"P6":
        sys.stderr.write("not a P6 PPM\n")
        sys.exit(2)
    dims = f.readline()
    while dims.startswith(b"#"):
        dims = f.readline()
    w, h = map(int, dims.split())
    f.readline()  # maxval
    data = f.read()
    return w, h, data


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: hb_rangeprog_probe.py FILE.ppm\n")
        sys.exit(2)
    w, h, data = _read_ppm(sys.argv[1])

    def px(x, y):
        i = (y * w + x) * 3
        return (data[i], data[i + 1], data[i + 2])

    def is_saturated(r, g, b):
        if r > 225 and g > 225 and b > 225:
            return False
        if r < 30 and g < 30 and b < 30:
            return False
        return (max(r, g, b) - min(r, g, b)) > 40

    # Per scanline: find the longest run of saturated pixels and its dominant
    # colour. A control bar is a wide (>=16px) coloured run.
    rows = []  # (y, color, runw)
    for y in range(h):
        run = 0
        best = 0
        best_end = 0
        for x in range(0, w):
            r, g, b = px(x, y)
            if is_saturated(r, g, b):
                run += 1
                if run > best:
                    best = run
                    best_end = x
            else:
                run = 0
        if best >= 16:
            # dominant colour across the winning run
            counts = {}
            x0 = best_end - best + 1
            for x in range(x0, best_end + 1):
                c = px(x, y)
                if is_saturated(*c):
                    counts[c] = counts.get(c, 0) + 1
            c = max(counts, key=counts.get)
            rows.append((y, c, best))

    # cluster rows into vertical bands (one per control).
    bands = []
    cur = []
    for row in rows:
        if cur and row[0] - cur[-1][0] > 5:
            bands.append(cur)
            cur = []
        cur.append(row)
    if cur:
        bands.append(cur)

    i = 0
    for b in bands:
        # widest run in the band + its colour (the mid-band scanline is fully
        # filled; use the max runw and the colour of that row).
        best_row = max(b, key=lambda r: r[2])
        y0 = b[0][0]
        c = best_row[1]
        fill = "#%02x%02x%02x" % c
        print("BAR i=%d y=%d fill=%s runw=%d" % (i, y0, fill, best_row[2]))
        i += 1


if __name__ == "__main__":
    main()
