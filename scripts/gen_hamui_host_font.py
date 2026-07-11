#!/usr/bin/env python3
# scripts/gen_hamui_host_font.py — regenerate lib/hamui_host_font.ad from the
# canonical 8x16 VGA bitmap font drivers/video/console/fb_font_8x16.S (the SAME
# font the GOP console + scene compositor draw). The host scene rasterizer
# (lib/hamui_host.ad) uses this so a host-rendered PNG shows the exact glyphs a
# native boot would. Run: python3 scripts/gen_hamui_host_font.py
import pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "drivers/video/console/fb_font_8x16.S"
b = []
for line in src.read_text().splitlines():
    line = line.strip()
    if line.startswith(".byte"):
        for tok in line[len(".byte"):].split(","):
            tok = tok.strip()
            if tok:
                b.append(int(tok, 16))
if len(b) != 2048:
    print(f"expected 2048 font bytes, got {len(b)}", file=sys.stderr)
    sys.exit(1)
hexstr = "".join("%02x" % x for x in b)
mod = '''# lib/hamui_host_font.ad — 8x16 VGA bitmap font for the HOST scene
# rasterizer (lib/hamui_host.ad). AUTO-GENERATED from
# drivers/video/console/fb_font_8x16.S (the SAME font the GOP console and
# scene compositor draw) by scripts/gen_hamui_host_font.py, so a
# host-rendered PNG shows the exact glyphs a native boot would.
#
# The 2048 font bytes (char N in 0..127 -> bytes N*16..N*16+15, each byte one
# 8-pixel scanline, MSB = leftmost pixel) are stored as a 4096-char ASCII-hex
# string (module-scope list/binary initialisers are unsupported by the x86
# codegen; a plain ASCII string with NO embedded NUL/quote is robust) and
# decoded once into a BSS table by hamui_host_font_init(). extern-free pure
# data + logic so it links into the x86_64-linux host target.

HAMUI_FONT_HEX: Array[4097, uint8] = "%s"
HAMUI_FONT_8X16: Array[2048, uint8]
_font_ready: int32 = 0


def _hexval(c: uint8) -> int32:
    if c >= 48 and c <= 57:
        return cast[int32](c) - 48
    if c >= 97 and c <= 102:
        return cast[int32](c) - 97 + 10
    if c >= 65 and c <= 70:
        return cast[int32](c) - 65 + 10
    return 0


def hamui_host_font_init():
    # Decode the 4096-char hex string into the 2048-byte glyph table (once).
    if _font_ready != 0:
        return
    i: uint64 = 0
    while i < 2048:
        hi: int32 = _hexval(HAMUI_FONT_HEX[i * 2])
        lo: int32 = _hexval(HAMUI_FONT_HEX[i * 2 + 1])
        HAMUI_FONT_8X16[i] = cast[uint8](hi * 16 + lo)
        i = i + 1
    _font_ready = 1


def hamui_host_font_row(ch: uint8, row: uint64) -> uint8:
    # Bitmap byte for glyph `ch` scanline `row` (0..15); blank if out of range.
    if ch >= 128 or row >= 16:
        return 0
    return HAMUI_FONT_8X16[cast[uint64](ch) * 16 + row]
''' % hexstr
(root / "lib/hamui_host_font.ad").write_text(mod)
print("wrote lib/hamui_host_font.ad (2048 glyph bytes)")
