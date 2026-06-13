#!/usr/bin/env python3
# scripts/gen_default_wallpaper.py — generate the DE default wallpaper.
#
# Output: a NetPBM P6 binary PPM at the given path (or
# user/share/wallpapers/default.ppm by default). The image is a simple
# diagonal slate-to-teal gradient — the same colour family as the
# default ROOT_R/G/B backdrop so the desktop reads consistently when the
# wallpaper hasn't been replaced.
#
# Public domain — no third-party assets, just a hand-coded gradient.
#
# Usage:
#   python3 scripts/gen_default_wallpaper.py [OUT_PATH] [WIDTH] [HEIGHT]
#
# Defaults: user/share/wallpapers/default.ppm, 320x240.
import os
import sys

DEF_OUT = os.path.join("user", "share", "wallpapers", "default.ppm")
DEF_W = 320
DEF_H = 240

# Two slate-ish endpoint colours — close to ROOT_R/G/B = (32, 48, 72)
# (slate) blended toward (28, 64, 70) (teal). Pure linear interpolation.
TL = (32, 48, 72)
BR = (28, 64, 90)


def generate(path: str, w: int, h: int) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pixels = bytearray(w * h * 3)
    for y in range(h):
        for x in range(w):
            # Diagonal blend factor in [0, 1].
            t = (x + y) / max(1, (w + h - 2))
            r = int(TL[0] + (BR[0] - TL[0]) * t)
            g = int(TL[1] + (BR[1] - TL[1]) * t)
            b = int(TL[2] + (BR[2] - TL[2]) * t)
            o = (y * w + x) * 3
            pixels[o] = r
            pixels[o + 1] = g
            pixels[o + 2] = b
    with open(path, "wb") as fh:
        fh.write(b"P6\n")
        header = f"{w} {h}\n255\n".encode("ascii")
        fh.write(header)
        fh.write(bytes(pixels))


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
