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
  3. resize the reference content box to the hambrowse content box (WxH) so the
     two are pixel-for-pixel comparable.

Because both engines are driven with the SAME DejaVu faces at the SAME default
UA sizes (16px body / 32px h1 / ...), the vertical + horizontal scale factors
here are close to 1.0 — the resize is a small correction, not a distortion that
manufactures agreement. The residual RMSE therefore tracks real LAYOUT + PAINT
differences (box geometry, borders, radii, shadows, baselines, spacing), which
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


def main():
    hb_path, ref_path, out_hb, out_ref = sys.argv[1:5]

    hb = flatten_white(Image.open(hb_path))
    hb = hb.crop(content_bbox(hb))
    hw, hh = hb.size

    ref = flatten_white(Image.open(ref_path))
    ref = ref.crop(content_bbox(ref))
    rw, rh = ref.size
    ref = ref.resize((hw, hh), Image.LANCZOS)

    hb.save(out_hb)
    ref.save(out_ref)
    print(f"hb_content={hw}x{hh} ref_content={rw}x{rh}->{hw}x{hh}")


if __name__ == "__main__":
    main()
