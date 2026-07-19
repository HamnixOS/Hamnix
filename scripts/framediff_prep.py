#!/usr/bin/env python3
"""scripts/framediff_prep.py — geometry normalizer for the browser fidelity
harness (scripts/framediff_run.sh).

hambrowse's host render-to-PNG (scripts/render_hambrowse_png.py) paints the
WINDOW CHROME (title bar + address bar + status bar) around the page content,
whereas a headless browser screenshot is pure page content. Before the two can
be diffed pixel-for-pixel they must describe the SAME rectangle at the SAME
dimensions. This helper does exactly that and nothing else:

  1. crop the hambrowse chrome off the top (TITLE_H+ADDR_H = 38px) and the
     status bar off the bottom (STATUS_H = 16px), leaving the content pane;
  2. trim the reference (chromium/firefox) screenshot down to its own content
     bounding box (drop the uniform trailing whitespace the fixed viewport
     leaves below a short page);
  3. resize the reference content to the hambrowse content's WxH so ImageMagick
     `compare` sees identical dimensions.

The vertical resize is a mild, documented distortion: hambrowse packs content on
a fixed 16px line grid while the browser uses proportional line boxes, so the
two content panes are rarely the same pixel height. Normalizing to a common box
keeps the RMSE metric a stable RELATIVE dev signal across engine iterations; it
is not a claim of pixel-exact parity. See docs/browser_framediff.md.

USAGE
  framediff_prep.py HB_FULL.png REF.png OUT_HB.png OUT_REF.png
"""
import sys
from PIL import Image

# mirror scripts/render_hambrowse_png.py chrome geometry
CHROME_TOP = 38     # TITLE_H(18) + ADDR_Y..ADDR_H -> content starts at y=38
CHROME_BOT = 16     # STATUS_H
WHITE = (255, 255, 255)


def crop_hb_content(path):
    """Strip window chrome, return the page content pane."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    bot = max(CHROME_TOP + 1, h - CHROME_BOT)
    return im.crop((0, CHROME_TOP, w, bot))


def content_bbox_height(im, bg=WHITE, pad=2):
    """Last non-background row + pad, scanning from the bottom up.

    A fixed-viewport browser screenshot of a short page is content at the top
    over a tall uniform background; we keep the full width and trim the empty
    tail so the resize target is the real content, not the letterbox."""
    w, h = im.size
    px = im.load()
    last = 0
    for y in range(h - 1, -1, -1):
        row_bg = True
        # sample across the row (every 4px is plenty and fast)
        for x in range(0, w, 4):
            if px[x, y] != bg:
                row_bg = False
                break
        if not row_bg:
            last = y
            break
    return min(h, last + 1 + pad)


def main():
    hb_full, ref, out_hb, out_ref = sys.argv[1:5]
    hb = crop_hb_content(hb_full)
    hw, hh = hb.size

    r = Image.open(ref).convert("RGB")
    rw, rh = r.size
    # trim reference to its content height, keep matched width
    ch = content_bbox_height(r)
    r = r.crop((0, 0, rw, ch))
    # resize reference content to the hambrowse content box
    r = r.resize((hw, hh), Image.LANCZOS)

    hb.save(out_hb)
    r.save(out_ref)
    print(f"hb_content={hw}x{hh} ref_content={rw}x{ch}->{hw}x{hh}")


if __name__ == "__main__":
    main()
