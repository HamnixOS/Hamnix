#!/usr/bin/env python3
"""scripts/hb_emitalic_probe.py — faux-oblique (<em>/<i>) slant PNG-truth probe.

Reads the binary P6 PPM the REAL pixel backend (user/hambrowse_host_gfx.ad ->
lib/htmlpage + lib/htmlpaint) writes and measures the SLANT of a text run: for
each detected line of ink it computes the mean ink x at the TOP third of the
glyph band vs the BOTTOM third. A faux-oblique (sheared) run pushes its top to
the RIGHT of its bottom, so `top - bottom` is clearly POSITIVE; upright text is
~0. The gate renders the SAME word once plain and once in <em>/<i>/font-style
and asserts the italic line slants while the plain one does not.

This is a SHEAR of the single bitmap face (a synthesised oblique), NOT a true
italic typeface — see lib/htmlpaint.ad (_blit_ttf_glyph) / the DOC note.

Stdlib only (no PIL): the same P6 reader as scripts/ppm_to_png.py.

USAGE
  hb_emitalic_probe.py FILE.ppm XLO XHO   # x window to look at the run within

Prints one `LINE <first_y> <last_y> top=<x> bot=<x> slant=<top-bot>` per
detected text band (exit status always 0); the gate parses the slant values.
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


def main():
    ppm = sys.argv[1]
    xlo = int(sys.argv[2])
    xhi = int(sys.argv[3])
    w, h, pix = read_ppm(ppm)

    def ink_cols(y):
        cols = []
        row = y * w * 3
        for x in range(xlo, min(xhi, w)):
            o = row + x * 3
            # "ink" = clearly darker than the white page.
            if pix[o] < 140 and pix[o + 1] < 140 and pix[o + 2] < 140:
                cols.append(x)
        return cols

    inky = [y for y in range(h) if len(ink_cols(y)) >= 2]
    # group contiguous inked rows into text lines
    lines = []
    cur = []
    for y in inky:
        if cur and y - cur[-1] > 2:
            lines.append(cur)
            cur = []
        cur.append(y)
    if cur:
        lines.append(cur)

    for grp in lines:
        data = []
        for y in grp:
            cols = ink_cols(y)
            if cols:
                data.append((y, sum(cols) / len(cols)))
        if len(data) < 3:
            continue
        n = max(1, len(data) // 3)
        tc = sum(c for _, c in data[:n]) / n
        bc = sum(c for _, c in data[-n:]) / n
        print("LINE %d %d top=%.1f bot=%.1f slant=%.2f"
              % (grp[0], grp[-1], tc, bc, tc - bc))


if __name__ == "__main__":
    main()
