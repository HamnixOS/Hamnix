#!/usr/bin/env python3
# scripts/hb_h1noborder_probe.py — pixel-level assert for the hambrowse
# "spurious <h1> underline" fix. A plain <h1>/<h2> with NO CSS border must NOT
# render a thin full-width horizontal rule beneath it (an on-device QA bug where
# the engine's legacy heading-underline flag painted a light-grey hairline under
# every h1/h2, mimicking an unwanted `border-bottom`). Real browsers give a
# heading only larger bold type + margins, no border.
#
# Strategy, from the rendered P6 PPM + the gfx backend's geometry dump:
#   * parse the ROW records (top/h/base) and the heading face height (HFACE) to
#     locate each heading row and the EMPTY band just below it (between the
#     heading's bottom and the next row's text).
#   * assert NO row in that band is a near-full-width run of dark ink (a rule).
#   * assert the heading row ITSELF still carries substantial ink (bold + large
#     text did not vanish) and is TALLER than a body row (large font preserved).
# Stdlib only (reuses ppm_to_png.read_ppm). Usage:
#   hb_h1noborder_probe.py <dump.txt> <render.ppm>
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_to_png import read_ppm

fails = []


def main():
    dump_path, ppm_path = sys.argv[1], sys.argv[2]
    dump = open(dump_path, "r", errors="replace").read().splitlines()
    w, h, pix = read_ppm(ppm_path)

    def dark_count(y):
        if y < 0 or y >= h:
            return 0
        c = 0
        base = y * w * 3
        for x in range(w):
            o = base + x * 3
            if pix[o] < 240 or pix[o + 1] < 240 or pix[o + 2] < 240:
                c += 1
        return c

    # Parse ROW records: "ROW <idx> top <t> h <hh> base <b>".
    rows = []
    for ln in dump:
        t = ln.split()
        if len(t) >= 8 and t[0] == "ROW" and t[2] == "top" and t[4] == "h":
            rows.append((int(t[1]), int(t[3]), int(t[5])))
    if not rows:
        fails.append("no ROW records parsed from gfx dump")
        report()
        return

    # HFACE record: "HFACE <face> h <hh> bold <b>" — heading face pixel height.
    heading_h = None
    for ln in dump:
        t = ln.split()
        if len(t) >= 6 and t[0] == "HFACE" and t[2] == "h":
            heading_h = int(t[3])
    body_h = min(hh for (_i, _top, hh) in rows)

    # Identify heading rows = rows notably taller than the body row height.
    heading_rows = [(i, top, hh) for (i, top, hh) in rows if hh >= body_h + 6]
    if not heading_rows:
        fails.append(
            "no heading rows (taller than body) found — fixture/layout changed")

    FULL = int(w * 0.6)   # a "rule" spans most of the content width
    for (i, top, hh) in heading_rows:
        # heading itself must still have real ink (bold/large text present).
        top_ink = max(dark_count(y) for y in range(top, top + hh))
        if top_ink < 20:
            fails.append(f"heading row {i} has almost no ink (text vanished?)")
        # heading must be large (taller than a body row) — big font preserved.
        if heading_h is not None and hh < body_h + 6:
            fails.append(f"heading row {i} not larger than body text")
        # the EMPTY band below the heading (its bottom .. next row top+small)
        band_lo = top + hh
        # find next row's top to bound the band; else scan a fixed slab.
        nexts = [t2 for (_j, t2, _h2) in rows if t2 > top]
        band_hi = (min(nexts) if nexts else band_lo + 12)
        band_hi = min(band_hi, h)
        rule_ys = [y for y in range(band_lo, band_hi) if dark_count(y) >= FULL]
        if rule_ys:
            widths = {y: dark_count(y) for y in rule_ys}
            fails.append(
                f"SPURIOUS RULE under heading row {i}: full-width dark line(s) "
                f"at y={rule_ys} (dark px {widths}); band {band_lo}..{band_hi}")

    report()


def report():
    if fails:
        for f in fails:
            print("[hb-h1nb] FAIL", f)
        sys.exit(1)
    print("[hb-h1nb] PASS no spurious rule beneath h1/h2; headings still "
          "render large/inked")


if __name__ == "__main__":
    main()
