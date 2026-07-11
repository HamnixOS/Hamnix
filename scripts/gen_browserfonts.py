#!/usr/bin/env python3
# scripts/gen_browserfonts.py — regenerate lib/browserfonts.ad, which EMBEDS
# the four bundled DejaVu subset TrueType faces (fonts/dejavu-*.ttf) as ASCII-
# hex string literals so the NATIVE on-device browser (user/hambrowse.ad) can
# load real anti-aliased fonts WITHOUT reading files from the rootfs.
#
# The host driver (user/hambrowse_host_gfx.ad) still slurps the .ttf files at
# run time; only the native path needs them baked in. The faces are tiny
# (~8 KiB each) so the embedded hex adds ~63 KiB of rodata to /bin/hambrowse.
#
# Module-scope binary/list initialisers are unsupported by the x86 codegen, so
# (mirroring lib/hamui_host_font.ad) each face is a plain ASCII-hex string with
# no embedded NUL/quote, decoded once into a BSS byte buffer at load time.
#
# Run:  python3 scripts/gen_browserfonts.py
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
fonts = [
    ("SANS", "dejavu-sans.ttf", "FACE_TT_SANS"),
    ("BOLD", "dejavu-sans-bold.ttf", "FACE_TT_SANS_BOLD"),
    ("SERIF", "dejavu-serif.ttf", "FACE_TT_SERIF"),
    ("MONO", "dejavu-mono.ttf", "FACE_TT_MONO"),
]

face_blobs = []
for tag, fname, _face in fonts:
    data = (root / "fonts" / fname).read_bytes()
    face_blobs.append((tag, fname, _face, data))

lines = []
lines.append("# lib/browserfonts.ad — EMBEDDED DejaVu-subset TrueType faces for the")
lines.append("# NATIVE web browser (user/hambrowse.ad). AUTO-GENERATED from fonts/dejavu-")
lines.append("# *.ttf by scripts/gen_browserfonts.py — DO NOT EDIT BY HAND.")
lines.append("#")
lines.append("# The host driver reads the .ttf files directly; the native browser has no")
lines.append("# font files in its namespace, so the bytes are baked in here as ASCII-hex")
lines.append("# strings (module-scope binary initialisers are unsupported by the x86")
lines.append("# codegen) and decoded once into BSS buffers by browserfonts_load(), which")
lines.append("# then registers each face with the TrueType rasteriser via htmlpaint. PURE:")
lines.append("# no extern/syscall, so it also links into the x86_64-linux host target.")
lines.append("")
lines.append("from lib.htmlpaint import htmlpaint_load_ttf")
lines.append("from lib.font_ttf import FACE_TT_SANS, FACE_TT_SANS_BOLD, FACE_TT_SERIF, \\")
lines.append("    FACE_TT_MONO")
lines.append("")
lines.append("")

for tag, fname, _face, data in face_blobs:
    hexstr = "".join("%02x" % b for b in data)
    n = len(data)
    lines.append(f"# {fname}: {n} bytes")
    lines.append(f'_BF_{tag}_HEX: Array[{n * 2 + 1}, uint8] = "{hexstr}"')
    lines.append(f"_BF_{tag}_LEN: uint64 = {n}")
    lines.append(f"_bf_{tag.lower()}_buf: Array[{n}, uint8]")
    lines.append("")

lines.append("")
lines.append("_bf_loaded: int32 = 0")
lines.append("")
lines.append("")
lines.append("def _bf_hexval(c: uint8) -> int32:")
lines.append("    if c >= 48 and c <= 57:")
lines.append("        return cast[int32](c) - 48")
lines.append("    if c >= 97 and c <= 102:")
lines.append("        return cast[int32](c) - 97 + 10")
lines.append("    if c >= 65 and c <= 70:")
lines.append("        return cast[int32](c) - 65 + 10")
lines.append("    return 0")
lines.append("")
lines.append("")
lines.append("def _bf_decode(hex: Ptr[uint8], dst: Ptr[uint8], n: uint64):")
lines.append("    i: uint64 = 0")
lines.append("    while i < n:")
lines.append("        hi: int32 = _bf_hexval(hex[i * 2])")
lines.append("        lo: int32 = _bf_hexval(hex[i * 2 + 1])")
lines.append("        dst[i] = cast[uint8](hi * 16 + lo)")
lines.append("        i = i + 1")
lines.append("")
lines.append("")
lines.append("# Decode + register all four embedded faces with the TrueType rasteriser.")
lines.append("# Idempotent. Returns 1 if the sans face loaded (enough to render), else 0.")
lines.append("def browserfonts_load() -> int32:")
lines.append("    if _bf_loaded != 0:")
lines.append("        return 1")
for tag, fname, face, data in face_blobs:
    t = tag
    lines.append(f"    _bf_decode(&_BF_{t}_HEX[0], &_bf_{t.lower()}_buf[0], _BF_{t}_LEN)")
    lines.append(f"    htmlpaint_load_ttf({face}, &_bf_{t.lower()}_buf[0], _BF_{t}_LEN)")
lines.append("    _bf_loaded = 1")
lines.append("    return 1")
lines.append("")

out = root / "lib" / "browserfonts.ad"
out.write_text("\n".join(lines))
total = sum(len(d) for *_x, d in face_blobs)
print(f"wrote {out} ({total} font bytes across {len(face_blobs)} faces)")
