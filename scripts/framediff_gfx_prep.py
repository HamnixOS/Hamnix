#!/usr/bin/env python3
"""scripts/framediff_gfx_prep.py — geometry normalizer for the PIXEL browser
fidelity harness (scripts/framediff_gfx_run.sh).

Unlike the legacy text-mode harness (scripts/framediff_prep.py), the input here
is the REAL pixel render produced by the `hambrowse_host_gfx` backend
(lib/htmlpage + lib/htmlpaint) — the SAME layout+paint code that runs on device.
That output is PURE PAGE CONTENT painted from the top-left on white paper; there
is NO window chrome to strip. So normalization is only about making the
hambrowse canvas and the headless-browser screenshot describe the SAME rectangle
so ImageMagick `compare` is meaningful:

  1. flatten both images onto opaque white (kill any alpha);
  2. trim each image to its own content bounding box (drop uniform white
     margins the browser viewport / the canvas padding leave around content);
  3. TOP-LEFT-ALIGN both content boxes on a shared canvas (max width x max
     height of the two), padding the shorter/narrower one with white.

Both engines are driven with the SAME DejaVu faces at the SAME default UA sizes
(16px body / 32px h1 / ...), so horizontal + vertical scale is already ~1.0 and
NO resize is needed. The OLD normalizer resized the reference to hambrowse's
content box; that silently masked VERTICAL-RHYTHM errors — if hambrowse's line
pitch or inter-block spacing was uniformly off, the resize squashed the
reference to match and the diff normalized away. Padding to a common canvas
instead makes vertical position / pitch / height differences register as REAL
pixel diffs, so the residual RMSE honestly tracks LAYOUT + PAINT differences
(box geometry, borders, radii, shadows, baselines, and — now — spacing), which
is exactly the signal the engine team needs.

USAGE
  framediff_gfx_prep.py HB.png REF.png OUT_HB.png OUT_REF.png
"""
import sys
from PIL import Image

WHITE = (255, 255, 255)


def flatten_white(im):
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGB", im.size, WHITE)
        bg.paste(im, mask=im.split()[-1])
        return bg
    return im.convert("RGB")


def content_bbox(im, bg=WHITE, pad=2, thresh=6):
    """Bounding box of non-background pixels (fuzzy vs a flat bg)."""
    w, h = im.size
    px = im.load()
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(0, w):
            r, g, b = px[x, y]
            if abs(r - bg[0]) > thresh or abs(g - bg[1]) > thresh or abs(b - bg[2]) > thresh:
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    if maxx < 0:
        return (0, 0, w, h)  # all background; keep as-is
    minx = max(0, minx - pad)
    miny = max(0, miny - pad)
    maxx = min(w, maxx + 1 + pad)
    maxy = min(h, maxy + 1 + pad)
    return (minx, miny, maxx, maxy)


def pad_topleft(im, cw, ch):
    """Place `im` at the top-left of a cw x ch white canvas."""
    if im.size == (cw, ch):
        return im
    canvas = Image.new("RGB", (cw, ch), WHITE)
    canvas.paste(im, (0, 0))
    return canvas


def main():
    hb_path, ref_path, out_hb, out_ref = sys.argv[1:5]

    hb = flatten_white(Image.open(hb_path))
    hb = hb.crop(content_bbox(hb))
    hw, hh = hb.size

    ref = flatten_white(Image.open(ref_path))
    ref = ref.crop(content_bbox(ref))
    rw, rh = ref.size

    # TOP-LEFT-ALIGN both onto a shared canvas (max extent), padding with white.
    # No resize: vertical position / pitch / height differences must survive as
    # real pixel diffs (see module docstring).
    cw, ch = max(hw, rw), max(hh, rh)
    hb = pad_topleft(hb, cw, ch)
    ref = pad_topleft(ref, cw, ch)

    hb.save(out_hb)
    ref.save(out_ref)
    print(f"hb_content={hw}x{hh} ref_content={rw}x{rh} canvas={cw}x{ch}")


if __name__ == "__main__":
    main()
