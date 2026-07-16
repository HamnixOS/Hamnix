#!/usr/bin/env python3
# scripts/gen_test_video.py — synthesize the royalty-free MOTION video test clip.
#
# Produces tests/fixtures/videos/test.hmjv: a short (~3 s) animated clip encoded
# as MOTION-JPEG inside a trivial length-prefixed container ("HMJV"). Every
# frame is generated ENTIRELY by this script from first principles (a bouncing
# ball over a scrolling colour-sweep background + a big frame counter) — there
# is NO sampled third-party footage involved, so the result is an original work
# released into the public domain (CC0-1.0).
#
# It is the file baked into the OS image at /usr/share/videos/test.hmjv and the
# reference the decoder host-test (scripts/test_hamvideo_host.sh) checks
# lib/mjpegdemux.ad + lib/jpeg.ad against. Deterministic: same bytes every run.
#
#   python3 scripts/gen_test_video.py [out.hmjv]
#
# CONTAINER FORMAT ("HMJV", all little-endian) — a deliberately trivial
# Motion-JPEG carrier (AVI/MP4 demux descoped; see docs), mirroring how the
# audio track chose WAV over MP3: the CODEC (baseline JPEG) is the hard part,
# the container is just length-prefixed frames.
#
#   offset  0  magic       "HMJV"     (4 bytes)
#   offset  4  version     u16 = 1
#   offset  6  flags       u16 = 0
#   offset  8  width       u16  (pixels, <= 256 — kernel named-image cap)
#   offset 10  height      u16  (pixels, <= 256)
#   offset 12  fps         u16
#   offset 14  frame_count u16
#   offset 16  reserved    u32 = 0
#   offset 20  frames...   each: u32 jpeg_len, then jpeg_len bytes (baseline JFIF)
#
# Kept intentionally small (256x192, ~10 fps, ~3 s => ~30 baseline JPEGs) so it
# neither bloats the image nor overruns lib/jpeg.ad's 512x512 / the kernel's
# 256x256 named-image cap, and each frame decodes fast on the native target.

import io
import math
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

WIDTH = 256
HEIGHT = 192
FPS = 10
SECONDS = 3
FRAME_COUNT = FPS * SECONDS      # 30
QUALITY = 80


def _digit_glyphs():
    # 5x7 bitmap font for the digits 0-9 (drawn scaled so the counter is huge
    # and unmistakably animated) — no external font dependency.
    return {
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00110", "01000", "10000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    }


GLYPHS = _digit_glyphs()


def _draw_number(draw, n, x, y, scale, colour):
    for ci, ch in enumerate(str(n)):
        rows = GLYPHS[ch]
        gx = x + ci * (6 * scale)
        for ry, row in enumerate(rows):
            for rx, bit in enumerate(row):
                if bit == "1":
                    px = gx + rx * scale
                    py = y + ry * scale
                    draw.rectangle([px, py, px + scale - 1, py + scale - 1],
                                   fill=colour)


def render_frame(i: int) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT))
    px = img.load()
    phase = i / FRAME_COUNT
    # Scrolling diagonal colour-sweep background (obviously animated + never
    # blank; each frame has a unique dominant hue).
    for y in range(HEIGHT):
        for x in range(WIDTH):
            t = (x + y) / (WIDTH + HEIGHT)
            hue = (t + phase) % 1.0
            r = int(64 + 63 * math.sin(2 * math.pi * (hue + 0.00)))
            g = int(64 + 63 * math.sin(2 * math.pi * (hue + 0.33)))
            b = int(96 + 63 * math.sin(2 * math.pi * (hue + 0.66)))
            px[x, y] = (max(0, min(255, r)), max(0, min(255, g)),
                        max(0, min(255, b)))
    draw = ImageDraw.Draw(img)
    # A bouncing ball — clear horizontal + vertical motion frame to frame.
    margin = 28
    span_x = WIDTH - 2 * margin
    span_y = HEIGHT - 2 * margin
    tx = abs(((2 * i / FRAME_COUNT) % 2.0) - 1.0)
    ty = abs(((3 * i / FRAME_COUNT) % 2.0) - 1.0)
    cx = margin + tx * span_x
    cy = margin + ty * span_y
    rad = 20
    draw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                 fill=(255, 220, 40), outline=(20, 20, 20))
    # A big frame counter so a screendump PROVES which frame is on screen.
    _draw_number(draw, i, 8, 8, 4, (255, 255, 255))
    # A corner block that cycles R/G/B so even a colour-blind check sees motion.
    corner = [(220, 40, 40), (40, 200, 60), (60, 120, 255)][i % 3]
    draw.rectangle([WIDTH - 34, HEIGHT - 34, WIDTH - 6, HEIGHT - 6], fill=corner)
    return img


def encode_jpeg(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    # Baseline sequential JFIF (progressive/optimize OFF) with 4:2:0 chroma —
    # exactly the SOF0 subset lib/jpeg.ad decodes.
    img.save(buf, format="JPEG", quality=QUALITY, progressive=False,
             optimize=False, subsampling="4:2:0")
    return buf.getvalue()


def build_container() -> bytes:
    frames = [encode_jpeg(render_frame(i)) for i in range(FRAME_COUNT)]
    out = bytearray()
    out += b"HMJV"
    out += struct.pack("<HH", 1, 0)                 # version, flags
    out += struct.pack("<HH", WIDTH, HEIGHT)
    out += struct.pack("<HH", FPS, FRAME_COUNT)
    out += struct.pack("<I", 0)                      # reserved
    for jf in frames:
        out += struct.pack("<I", len(jf))
        out += jf
    return bytes(out)


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent.parent
        / "tests" / "fixtures" / "videos" / "test.hmjv")
    out.parent.mkdir(parents=True, exist_ok=True)
    data = build_container()
    out.write_bytes(data)
    print("wrote %s (%d bytes, %dx%d %d fps, %d frames, %.1fs, Motion-JPEG)" % (
        out, len(data), WIDTH, HEIGHT, FPS, FRAME_COUNT, FRAME_COUNT / FPS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
