#!/usr/bin/env python3
"""scripts/hb_grid_probe.py — CSS-Grid PNG probe for the native browser engine.

Runs the hambrowse host harness on an HTML fixture, renders the shared
parse+layout+colour dump to a real PNG (via scripts/render_hambrowse_png.py),
then LOOKS at the pixels: for each requested item background colour it locates
the box's ORIGIN (top-left pixel of that colour) and its extent. This is the
pixel-level truth the SEG-coordinate gates approximate — it proves each grid
item's box actually paints at the computed track x/row in the rendered image.

USAGE
  hb_grid_probe.py BIN FIX.html WIDTH OUT.png RRGGBB[,RRGGBB...]

Prints one line per colour:
  FOUND #rrggbb x=<left> y=<top> w=<width> h=<height> n=<pixelcount>
  MISS  #rrggbb                       (colour not present in the PNG)
Exit status is always 0; the calling gate parses these lines and asserts.
"""
import subprocess
import sys
import os

from PIL import Image


def _hex_to_rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def _close(a, b, tol=24):
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def main():
    if len(sys.argv) < 6:
        sys.stderr.write("usage: hb_grid_probe.py BIN FIX WIDTH OUT.png C[,C...]\n")
        sys.exit(2)
    binp, fix, width, outpng, colors = sys.argv[1:6]
    here = os.path.dirname(os.path.abspath(__file__))
    render = os.path.join(here, "render_hambrowse_png.py")

    dump = subprocess.run([binp, fix, str(width)],
                          capture_output=True, text=True).stdout
    # Render the dump to a PNG (render script reads the dump on stdin).
    subprocess.run([sys.executable, render, outpng],
                   input=dump, text=True, check=True)

    img = Image.open(outpng).convert("RGB")
    px = img.load()
    W, H = img.size
    for c in colors.split(","):
        want = _hex_to_rgb(c)
        minx = miny = 10 ** 9
        maxx = maxy = -1
        n = 0
        for y in range(H):
            for x in range(W):
                if _close(px[x, y], want):
                    n += 1
                    if x < minx:
                        minx = x
                    if y < miny:
                        miny = y
                    if x > maxx:
                        maxx = x
                    if y > maxy:
                        maxy = y
        if n == 0:
            print("MISS  #%s" % c.lstrip("#"))
        else:
            print("FOUND #%s x=%d y=%d w=%d h=%d n=%d" %
                  (c.lstrip("#"), minx, miny, maxx - minx + 1, maxy - miny + 1, n))


if __name__ == "__main__":
    main()
