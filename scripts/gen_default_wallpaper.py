#!/usr/bin/env python3
# scripts/gen_default_wallpaper.py — generate the DE default wallpaper.
#
# Output: a NetPBM P6 binary PPM at the given path (or
# user/share/wallpapers/default.ppm by default).
#
# The wallpaper is a hand-coded blend so the DE doesn't ship as a flat
# grey slab. We render a vertical dark-blue gradient (midnight at the
# top, lighter blue at the bottom) and lay a soft elliptical radial
# vignette over it, then add a couple of subtle "ridge" arcs in the
# lower third for a hint of geometry — basically the 2000s-desktop
# look, deliberately understated so it doesn't fight panel chrome.
#
# Public domain — no third-party assets, just hand-coded math.
#
# Usage:
#   python3 scripts/gen_default_wallpaper.py [OUT_PATH] [WIDTH] [HEIGHT]
#
# Defaults: user/share/wallpapers/default.ppm, 640x480.
#
# NOTE: user/hamUId.ad caps the decoded wallpaper buffer at
# WALLPAPER_MAX_W=640 / WALLPAPER_MAX_H=480 (921600 bytes). Anything
# larger is rejected by ppm_parse_p6, so 640x480 is the practical max
# until the buffer is grown.
import math
import os
import sys

DEF_OUT = os.path.join("user", "share", "wallpapers", "default.ppm")
DEF_W = 640
DEF_H = 480

# Top and bottom of the base vertical gradient. Midnight -> lighter
# slate blue. Keeps the same colour family as ROOT_R/G/B (32,48,72) so
# the panel + window chrome read against it.
TOP = (12, 18, 38)      # near-black indigo
BOTTOM = (40, 70, 120)  # muted denim


def _lerp(a: int, b: int, t: float) -> int:
    v = int(a + (b - a) * t + 0.5)
    if v < 0:
        return 0
    if v > 255:
        return 255
    return v


def _ridge_lift(x: int, y: int, w: int, h: int) -> int:
    # A pair of broad, low-amplitude horizontal "ridges" in the lower
    # half. Sine arc, soft-falloff envelope so they fade above the
    # midline. Adds 0..~22 to the blue channel.
    if y < h // 2:
        return 0
    # Two arcs: one slow, one twice as fast and dimmer.
    nx = x / max(1, w - 1)
    ny = (y - h / 2) / max(1, h / 2)
    arc1 = math.sin(nx * math.pi * 1.5 + 0.4) * 0.5 + 0.5
    arc2 = math.sin(nx * math.pi * 3.0 + 1.8) * 0.5 + 0.5
    env = ny ** 1.3   # 0 at midline, 1 at bottom
    return int((arc1 * 0.65 + arc2 * 0.35) * env * 22.0)


def _vignette(x: int, y: int, w: int, h: int) -> float:
    # Soft elliptical vignette centred on the image. 1.0 in the centre,
    # tapering toward ~0.78 in the corners. Returns the multiplier.
    cx = (w - 1) / 2.0
    cy = (h - 1) / 2.0
    dx = (x - cx) / cx
    dy = (y - cy) / cy
    d2 = dx * dx + dy * dy           # 0..~2
    # Smooth quadratic fall-off, clamped.
    fall = max(0.0, min(1.0, d2 * 0.5))
    return 1.0 - 0.22 * fall


def generate(path: str, w: int, h: int) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pixels = bytearray(w * h * 3)
    for y in range(h):
        t = y / max(1, h - 1)
        # Base vertical gradient.
        br = _lerp(TOP[0], BOTTOM[0], t)
        bg = _lerp(TOP[1], BOTTOM[1], t)
        bb = _lerp(TOP[2], BOTTOM[2], t)
        for x in range(w):
            vmul = _vignette(x, y, w, h)
            lift = _ridge_lift(x, y, w, h)
            r = int(br * vmul)
            g = int(bg * vmul)
            b = int(bb * vmul) + lift
            if r < 0: r = 0
            if g < 0: g = 0
            if b < 0: b = 0
            if r > 255: r = 255
            if g > 255: g = 255
            if b > 255: b = 255
            o = (y * w + x) * 3
            pixels[o] = r
            pixels[o + 1] = g
            pixels[o + 2] = b
    with open(path, "wb") as fh:
        fh.write(b"P6\n")
        header = f"{w} {h}\n255\n".encode("ascii")
        fh.write(header)
        fh.write(bytes(pixels))


def build_default_wallpaper(w: int = DEF_W, h: int = DEF_H) -> bytes:
    """Return the encoded PPM bytes for the default wallpaper.

    Convenience for build_initramfs.py: skips writing a file on disk and
    just hands back the in-memory P6 payload.
    """
    pixels = bytearray(w * h * 3)
    for y in range(h):
        t = y / max(1, h - 1)
        br = _lerp(TOP[0], BOTTOM[0], t)
        bg = _lerp(TOP[1], BOTTOM[1], t)
        bb = _lerp(TOP[2], BOTTOM[2], t)
        for x in range(w):
            vmul = _vignette(x, y, w, h)
            lift = _ridge_lift(x, y, w, h)
            r = int(br * vmul)
            g = int(bg * vmul)
            b = int(bb * vmul) + lift
            if r < 0: r = 0
            if g < 0: g = 0
            if b < 0: b = 0
            if r > 255: r = 255
            if g > 255: g = 255
            if b > 255: b = 255
            o = (y * w + x) * 3
            pixels[o] = r
            pixels[o + 1] = g
            pixels[o + 2] = b
    header = f"P6\n{w} {h}\n255\n".encode("ascii")
    return bytes(header + pixels)


def main(argv):
    out = argv[1] if len(argv) > 1 else DEF_OUT
    w = int(argv[2]) if len(argv) > 2 else DEF_W
    h = int(argv[3]) if len(argv) > 3 else DEF_H
    if w <= 0 or h <= 0:
        print("gen_default_wallpaper: bad dimensions", file=sys.stderr)
        return 1
    generate(out, w, h)
    print(f"wrote {out} ({w}x{h}, {os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
