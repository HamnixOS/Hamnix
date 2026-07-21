#!/usr/bin/env python3
"""scripts/framediff_metric.py — STRUCTURAL fidelity metric for the browser
framediff harness.

WHY THIS EXISTS
===============
The harness used to score hambrowse-vs-Chrome with raw full-frame RMSE. That is
a poor parity signal for a page renderer for two reasons:

  1. **Area-scaling** — a big, *correct* glyph block (a real <h1> at 34px) covers
     many pixels, so its unavoidable per-pixel antialias/hinting mismatch vs
     Chrome sums to a LARGER absolute error than a tiny wrong render. Raw RMSE
     therefore ROSE when a prior round started rendering headings at true size —
     it punished the fidelity gain. (Documented failure that got reverted.)
  2. **Subpixel misregistration** — even a structurally perfect render sits a
     pixel or two off Chrome's baseline (different font, hinting, rounding). Raw
     RMSE sees every antialiased edge as a full-contrast error along that seam.

Both are exactly the differences a human reader does NOT care about. We want a
metric that scores a render which STRUCTURALLY matches Chrome (right boxes, right
text at the right place and size) as GOOD even when per-pixel AA differs.

THE METRIC
==========
Two complementary, well-established measures, both tolerant of subpixel AA:

  * **SSIM** (structural similarity, Wang et al. 2004) over an 11px Gaussian
    window on luminance — the standard perceptual structure metric. Reported as
    `ssim` in 0..1, HIGHER = better. We also report `dssim = 1 - ssim` so the
    "lower == closer" convention of the doc holds for every column.

  * **Blurred RMSE (`brmse`)** — downsample 4x (box) then a light Gaussian, then
    RMSE. The blur smears out 1-3px AA/baseline offsets so aligned structures
    match, while genuinely wrong layout (missing box, wrong heading size, text in
    the wrong place) still survives the blur as a coarse-scale difference. 0..1,
    LOWER = better. This is the primary structural distance.

`rmse` (raw, 0..1) is still reported for continuity with older tables.

USAGE
  framediff_metric.py HB.png REF.png            # both must be the SAME size
  -> prints:  rmse=<f> brmse=<f> ssim=<f> dssim=<f>
"""
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter
from skimage.metrics import structural_similarity as ssim


def _load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def _luma(a):
    # Rec.601 luminance
    return a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114


def raw_rmse(a, b):
    return float(np.sqrt(np.mean((a - b) ** 2)) / 255.0)


def blurred_rmse(a, b, factor=4, sigma=1.5):
    """Downsample by `factor` (area/box average) then light Gaussian, then RMSE.
    Tolerates subpixel AA + a few px of baseline misregistration; keeps coarse
    layout error."""
    def prep(x):
        img = Image.fromarray(np.clip(x, 0, 255).astype(np.uint8))
        w, h = img.size
        img = img.resize((max(1, w // factor), max(1, h // factor)),
                         Image.BOX)
        arr = np.asarray(img, dtype=np.float64)
        for c in range(3):
            arr[..., c] = gaussian_filter(arr[..., c], sigma=sigma)
        return arr
    pa, pb = prep(a), prep(b)
    return float(np.sqrt(np.mean((pa - pb) ** 2)) / 255.0)


def main():
    hb, ref = sys.argv[1:3]
    a, b = _load(hb), _load(ref)
    if a.shape != b.shape:
        # defensive — the prep step should already have matched sizes
        b = np.asarray(Image.open(ref).convert("RGB").resize(
            (a.shape[1], a.shape[0]), Image.LANCZOS), dtype=np.float64)
    rmse = raw_rmse(a, b)
    brmse = blurred_rmse(a, b)
    # SSIM on luminance with the standard 11px Gaussian window.
    win = 11
    if min(a.shape[0], a.shape[1]) < win:
        win = max(3, (min(a.shape[0], a.shape[1]) // 2) * 2 + 1)
    s = float(ssim(_luma(a), _luma(b), data_range=255.0,
                   gaussian_weights=True, sigma=1.5, win_size=win,
                   use_sample_covariance=False))
    print(f"rmse={rmse:.6f} brmse={brmse:.6f} ssim={s:.6f} dssim={1.0 - s:.6f}")


if __name__ == "__main__":
    main()
