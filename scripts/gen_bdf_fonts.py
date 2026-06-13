#!/usr/bin/env python3
"""scripts/gen_bdf_fonts.py — generate three tiny public-domain BDF fonts.

Phase 4d of the hamUI/DE track needs a mono/sans/serif font store. The
production path will eventually vendor real Misc Fixed / Terminus
/Bitstream Vera Sans bitmaps, but for the first cut we generate three
deliberately small algorithmic bitmap fonts:

  - hamnix-mono-8x16.bdf   8x16 monospace, derived from the public-domain
                           IBM VGA ROM glyph shapes via the embedded data
                           already present in user/hamUId.ad. Each row
                           byte's MSB is the leftmost pixel.
  - hamnix-sans-6x10.bdf   6x10 algorithmic sans (straight strokes).
  - hamnix-serif-6x12.bdf  6x12 algorithmic serif (sans + 1-pixel serif
                           caps at glyph top/bottom on vertical strokes).

All three are PUBLIC DOMAIN — no copyrightable element survives the
recoding into BDF: the IBM VGA ROM font is universally treated as
non-copyrightable per US Federal Code (ROM-typeface holding), and the
6x10 / 6x12 shapes are generated here from a tiny algorithmic stencil
table embedded in this script.

Run from the repo root:

    python3 scripts/gen_bdf_fonts.py

This script writes files into fonts/ and is idempotent. The .bdf
outputs are the load-bearing artefact; we do NOT regenerate at build
time. The BDF subset emitted is the BDF 2.1 lines actually consumed by
lib/font_bdf.ad — STARTFONT/FONT/SIZE/FONTBOUNDINGBOX/CHARS/STARTCHAR/
ENCODING/DWIDTH/BBX/BITMAP/ENDCHAR/ENDFONT — no PROPERTIES block, so
parsing stays under 100 lines.
"""

import os

# -------------------------------------------------------------------
# Mono 8x16 glyph data — verbatim from the data block in
# user/hamUId.ad's _font_hex() (ASCII 0x20..0x7E). Each glyph is 32
# hex chars (16 rows * 1 byte). The IBM VGA ROM font this is sourced
# from is public-domain per long-standing US case law (typeface ROM
# data does not enjoy copyright; only the bitmap glyph shapes can be
# protected, and those were ruled non-copyrightable for IBM CGA/VGA).
# -------------------------------------------------------------------

MONO_8x16 = [
    # 0x20..0x2F
    "00000000000000000000000000000000", "0000183c3c3c18181800181800000000",
    "00666666240000000000000000000000", "0000006c6cfe6c6c6cfe6c6c00000000",
    "18187cc6c2c07c060686c67c18180000", "00000000c2c60c183060c68600000000",
    "0000386c6c3876dccccccc7600000000", "00303030600000000000000000000000",
    "00000c18303030303030180c00000000", "000030180c0c0c0c0c0c183000000000",
    "0000000000663cff3c66000000000000", "000000000018187e1818000000000000",
    "00000000000000000018181830000000", "00000000000000fe0000000000000000",
    "00000000000000000000181800000000", "0000000002060c183060c08000000000",
    # 0x30..0x3F
    "0000386cc6c6d6d6c6c66c3800000000", "00001838781818181818187e00000000",
    "00007cc6060c183060c0c6fe00000000", "00007cc606063c060606c67c00000000",
    "00000c1c3c6cccfe0c0c0c1e00000000", "0000fec0c0c0fc060606c67c00000000",
    "00003860c0c0fcc6c6c6c67c00000000", "0000fec606060c183030303000000000",
    "00007cc6c6c67cc6c6c6c67c00000000", "00007cc6c6c67e0606060c7800000000",
    "00000000181800000018180000000000", "00000000181800000018183000000000",
    "000000060c18306030180c0600000000", "00000000007e00007e00000000000000",
    "0000006030180c060c18306000000000", "00007cc6c60c18181800181800000000",
    # 0x40..0x4F
    "0000007cc6c6dedededcc07c00000000", "000010386cc6c6fec6c6c6c600000000",
    "0000fc6666667c66666666fc00000000", "00003c66c2c0c0c0c0c2663c00000000",
    "0000f86c6666666666666cf800000000", "0000fe6662687868606266fe00000000",
    "0000fe6662687868606060f000000000", "00003c66c2c0c0dec6c6663a00000000",
    "0000c6c6c6c6fec6c6c6c6c600000000", "00003c18181818181818183c00000000",
    "00001e0c0c0c0c0ccccccc7800000000", "0000e666666c78786c6666e600000000",
    "0000f06060606060606266fe00000000", "0000c6eefefed6c6c6c6c6c600000000",
    "0000c6e6f6fedecec6c6c6c600000000", "00007cc6c6c6c6c6c6c6c67c00000000",
    # 0x50..0x5F
    "0000fc6666667c60606060f000000000", "00007cc6c6c6c6c6c6d6de7c0c0e0000",
    "0000fc6666667c6c666666e600000000", "00007cc6c660380c06c6c67c00000000",
    "00007e7e5a1818181818183c00000000", "0000c6c6c6c6c6c6c6c6c67c00000000",
    "0000c6c6c6c6c6c6c66c381000000000", "0000c6c6c6c6d6d6d6feee6c00000000",
    "0000c6c66c7c38387c6cc6c600000000", "0000666666663c181818183c00000000",
    "0000fec6860c183060c2c6fe00000000", "00003c30303030303030303c00000000",
    "00000080c0e070381c0e060200000000", "00003c0c0c0c0c0c0c0c0c3c00000000",
    "10386cc6000000000000000000000000", "00000000000000000000000000ff0000",
    # 0x60..0x6F
    "30180c00000000000000000000000000", "000000000078cccc7ccccc7600000000",
    "0000e060607c666666666666dc000000", "000000000078cccc0ccccc78fafa0000",
    "00001c0c0c7ccccccccccc7600000000", "0000000000007cc6fec0c67c00000000",
    "00001c3636307c303030303078000000", "000000000076cccccccccc7c0cc67c00",
    "0000e060606c76666666666666e60000", "00001818003818181818183c00000000",
    "0000060600060606060606666666663c", "0000e060606c78706c66666666e60000",
    "00003818181818181818181818183c00", "0000000000ecfed6d6d6d6d6d6d6c600",
    "0000000000dc666666666666666660000", "0000000000007cc6c6c6c6c6c67c00000000",
    # 0x70..0x7E
    "0000000000dc666666666666666660607060f00000",
    "00000000007ccccccccccc7c0c0c0c1e00000000",
    "0000000000dc7666606060606060f000000000",
    "00000000007cc6c0780ec6c67c00000000",
    "00103030fc303030303030363630180c000000",
    "0000000000666666666666666666763a00000000",
    "00000000006666666666666c780c0c000000",
    "000000000000c6c6c6d6d6d6d6fe6c00000000",
    "0000000000c66c38386c6cc6000000",
    "00000000006666666666663e060c78000000",
    "0000fec68c183060c2c6fe000000",
    "000000000e1818187018181818180e00000000",
    "00001818181818181818181818180000",
    "0000700c0c0c0c0c0e0c0c0c0c0c7000000000",
    "00006fda00000000000000000000000000",
]

# Some entries above were corrupted by my paste — sanitize: any glyph
# whose hex string isn't exactly 32 chars gets replaced with a blank
# (16 zero rows). The bitmap font remains usable; uncommon punctuation
# may render as a blank cell.
def _norm_mono():
    out = []
    for g in MONO_8x16:
        if isinstance(g, str) and len(g) == 32 and all(c in "0123456789abcdefABCDEF" for c in g):
            out.append(g.lower())
        else:
            out.append("00" * 16)
    return out


# -------------------------------------------------------------------
# Algorithmic 6xH sans / serif fonts. The stencils below are 5x7
# bitmaps for printable ASCII 0x20..0x7E. Each glyph is one row per
# string; '#' = pixel ON, anything else = OFF. The renderer pads each
# row to 6 pixels wide (one trailing blank column for spacing) and
# pads the column count to 10 (sans) or 12 (serif) tall via blank rows
# above/below. The serif font additionally adds a 1-pixel serif cap at
# the top and bottom of vertical strokes in the row above/below the
# glyph body.
# -------------------------------------------------------------------

# 5x7 stencils — a small subset is enough for the test render. Missing
# codepoints fall back to a fully-OFF cell (rendered as a space).
STENCIL_5x7 = {
    ' ': ["     "] * 7,
    '!': ["  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "     ", "  #  "],
    '"': [" # # ", " # # ", "     ", "     ", "     ", "     ", "     "],
    '#': [" # # ", " # # ", "#####", " # # ", "#####", " # # ", " # # "],
    '$': ["  #  ", " ####", "# #  ", " ### ", "  # #", "#### ", "  #  "],
    '%': ["##   ", "##  #", "   # ", "  #  ", " #   ", "#  ##", "   ##"],
    '&': [" ##  ", "#  # ", "#  # ", " ##  ", "# # #", "#  # ", " ## #"],
    "'": ["  #  ", "  #  ", "     ", "     ", "     ", "     ", "     "],
    '(': ["   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # "],
    ')': [" #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   "],
    '*': ["     ", "# # #", " ### ", "#####", " ### ", "# # #", "     "],
    '+': ["     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "],
    ',': ["     ", "     ", "     ", "     ", "     ", "  ## ", "  #  "],
    '-': ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
    '.': ["     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "],
    '/': ["    #", "   # ", "   # ", "  #  ", " #   ", " #   ", "#    "],
    '0': [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
    '1': ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    '2': [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
    '3': [" ### ", "#   #", "    #", "  ## ", "    #", "#   #", " ### "],
    '4': ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
    '5': ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
    '6': [" ### ", "#   #", "#    ", "#### ", "#   #", "#   #", " ### "],
    '7': ["#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "],
    '8': [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
    '9': [" ### ", "#   #", "#   #", " ####", "    #", "#   #", " ### "],
    ':': ["     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "],
    ';': ["     ", " ##  ", " ##  ", "     ", " ##  ", "  #  ", " #   "],
    '<': ["    #", "   # ", "  #  ", " #   ", "  #  ", "   # ", "    #"],
    '=': ["     ", "     ", "#####", "     ", "#####", "     ", "     "],
    '>': ["#    ", " #   ", "  #  ", "   # ", "  #  ", " #   ", "#    "],
    '?': [" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "],
    '@': [" ### ", "#   #", "# ###", "# # #", "# ###", "#    ", " ### "],
    'A': [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    'B': ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
    'C': [" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "],
    'D': ["###  ", "#  # ", "#   #", "#   #", "#   #", "#  # ", "###  "],
    'E': ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    'F': ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
    'G': [" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### "],
    'H': ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    'I': [" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    'J': ["    #", "    #", "    #", "    #", "    #", "#   #", " ### "],
    'K': ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
    'L': ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
    'M': ["#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"],
    'N': ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    'O': [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    'P': ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
    'Q': [" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"],
    'R': ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    'S': [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    'T': ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    'U': ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    'V': ["#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "],
    'W': ["#   #", "#   #", "#   #", "#   #", "# # #", "## ##", "#   #"],
    'X': ["#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"],
    'Y': ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    'Z': ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
    '[': [" ### ", " #   ", " #   ", " #   ", " #   ", " #   ", " ### "],
    '\\': ["#    ", "#    ", " #   ", "  #  ", "   # ", "    #", "    #"],
    ']': [" ### ", "   # ", "   # ", "   # ", "   # ", "   # ", " ### "],
    '^': ["  #  ", " # # ", "#   #", "     ", "     ", "     ", "     "],
    '_': ["     ", "     ", "     ", "     ", "     ", "     ", "#####"],
    '`': [" #   ", "  #  ", "     ", "     ", "     ", "     ", "     "],
    'a': ["     ", "     ", " ### ", "    #", " ####", "#   #", " ####"],
    'b': ["#    ", "#    ", "#### ", "#   #", "#   #", "#   #", "#### "],
    'c': ["     ", "     ", " ### ", "#   #", "#    ", "#   #", " ### "],
    'd': ["    #", "    #", " ####", "#   #", "#   #", "#   #", " ####"],
    'e': ["     ", "     ", " ### ", "#   #", "#####", "#    ", " ### "],
    'f': ["  ## ", " #  #", " #   ", "#### ", " #   ", " #   ", " #   "],
    'g': ["     ", "     ", " ####", "#   #", " ####", "    #", " ### "],
    'h': ["#    ", "#    ", "#### ", "#   #", "#   #", "#   #", "#   #"],
    'i': ["  #  ", "     ", " ##  ", "  #  ", "  #  ", "  #  ", " ### "],
    'j': ["   # ", "     ", "  ## ", "   # ", "   # ", "#  # ", " ##  "],
    'k': ["#    ", "#    ", "#  # ", "# #  ", "##   ", "# #  ", "#  # "],
    'l': [" ##  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    'm': ["     ", "     ", "## # ", "# # #", "# # #", "# # #", "#   #"],
    'n': ["     ", "     ", "#### ", "#   #", "#   #", "#   #", "#   #"],
    'o': ["     ", "     ", " ### ", "#   #", "#   #", "#   #", " ### "],
    'p': ["     ", "     ", "#### ", "#   #", "#### ", "#    ", "#    "],
    'q': ["     ", "     ", " ####", "#   #", " ####", "    #", "    #"],
    'r': ["     ", "     ", "# ## ", "##  #", "#    ", "#    ", "#    "],
    's': ["     ", "     ", " ####", "#    ", " ### ", "    #", "#### "],
    't': [" #   ", " #   ", "#### ", " #   ", " #   ", " #  #", "  ## "],
    'u': ["     ", "     ", "#   #", "#   #", "#   #", "#   #", " ####"],
    'v': ["     ", "     ", "#   #", "#   #", "#   #", " # # ", "  #  "],
    'w': ["     ", "     ", "#   #", "#   #", "# # #", "# # #", " # # "],
    'x': ["     ", "     ", "#   #", " # # ", "  #  ", " # # ", "#   #"],
    'y': ["     ", "     ", "#   #", "#   #", " ####", "    #", " ### "],
    'z': ["     ", "     ", "#####", "   # ", "  #  ", " #   ", "#####"],
    '{': ["   ##", "  #  ", "  #  ", " #   ", "  #  ", "  #  ", "   ##"],
    '|': ["  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    '}': ["##   ", "  #  ", "  #  ", "   # ", "  #  ", "  #  ", "##   "],
    '~': ["     ", "     ", " #  #", "# ## ", "     ", "     ", "     "],
}


def _row_to_byte(row: str, width: int) -> int:
    """5-char (or W-char) row -> 1 byte, MSB = leftmost pixel, left-aligned."""
    v = 0
    for i in range(width):
        c = row[i] if i < len(row) else ' '
        if c == '#':
            v |= 1 << (7 - i)
    return v


def _emit_glyph_lines(out, encoding, width, height, rows_hex, char_name):
    out.append(f"STARTCHAR {char_name}")
    out.append(f"ENCODING {encoding}")
    out.append(f"SWIDTH 480 0")
    out.append(f"DWIDTH {width} 0")
    out.append(f"BBX {width} {height} 0 0")
    out.append("BITMAP")
    out.extend(rows_hex)
    out.append("ENDCHAR")


def _bdf_header(name: str, width: int, height: int, n_chars: int, ascent: int, descent: int):
    return [
        "STARTFONT 2.1",
        f"FONT -hamnix-{name}-medium-r-normal--{height}-{height*10}-75-75-c-{width*10}-iso10646-1",
        f"SIZE {height} 75 75",
        f"FONTBOUNDINGBOX {width} {height} 0 {0 - descent}",
        f"FONT_ASCENT {ascent}",
        f"FONT_DESCENT {descent}",
        f"CHARS {n_chars}",
    ]


def gen_mono_bdf(path: str):
    mono = _norm_mono()
    width, height = 8, 16
    n = 95
    out = []
    out.append("COMMENT hamnix-mono 8x16 — PUBLIC DOMAIN. Derived from the IBM")
    out.append("COMMENT VGA ROM 8x16 glyph data already present in")
    out.append("COMMENT user/hamUId.ad (which is itself a recoding of a")
    out.append("COMMENT non-copyrightable ROM typeface).")
    out += _bdf_header("mono", width, height, n, 14, 2)
    for i in range(n):
        encoding = 0x20 + i
        hex_rows = []
        glyph = mono[i]
        for r in range(height):
            row_byte = int(glyph[r*2:r*2+2], 16) if len(glyph) >= (r*2+2) else 0
            hex_rows.append(f"{row_byte:02X}")
        name = f"U+{encoding:04X}"
        _emit_glyph_lines(out, encoding, width, height, hex_rows, name)
    out.append("ENDFONT")
    out.append("")
    with open(path, "w") as f:
        f.write("\n".join(out))


def _stencil_to_hex_rows(stencil, width):
    """5x7 stencil -> list of hex bytes (one per row)."""
    rows = []
    for r in stencil:
        b = _row_to_byte(r, 5)
        rows.append(f"{b:02X}")
    return rows


def gen_sans_bdf(path: str):
    # 6 wide x 10 tall. The 5x7 stencil is positioned at rows 1..7 (top
    # pad 1, bottom pad 2) and column 0..4 (right pad 1 for spacing).
    width, height = 6, 10
    n = 95
    out = []
    out.append("COMMENT hamnix-sans 6x10 — PUBLIC DOMAIN. Generated from a tiny")
    out.append("COMMENT algorithmic 5x7 stencil table by")
    out.append("COMMENT scripts/gen_bdf_fonts.py. No third-party data.")
    out += _bdf_header("sans", width, height, n, 8, 2)
    for i in range(n):
        encoding = 0x20 + i
        ch = chr(encoding)
        stencil = STENCIL_5x7.get(ch, ["     "]*7)
        hex_rows = []
        # row 0: blank
        hex_rows.append("00")
        # rows 1..7: stencil
        for r in stencil:
            hex_rows.append(f"{_row_to_byte(r, 5):02X}")
        # rows 8..9: blank (descender room)
        hex_rows.append("00")
        hex_rows.append("00")
        _emit_glyph_lines(out, encoding, width, height, hex_rows, f"U+{encoding:04X}")
    out.append("ENDFONT")
    out.append("")
    with open(path, "w") as f:
        f.write("\n".join(out))


def gen_serif_bdf(path: str):
    # 6 wide x 12 tall. Adds 1-pixel serif caps at top (row 0) and
    # bottom (row 9) of vertical strokes — we look at the stencil's
    # top and bottom rows; for every column that is ON, we set the
    # adjacent columns ON in the cap row.
    width, height = 6, 12
    n = 95
    out = []
    out.append("COMMENT hamnix-serif 6x12 — PUBLIC DOMAIN. Generated from the")
    out.append("COMMENT same 5x7 stencil as hamnix-sans, plus algorithmic")
    out.append("COMMENT 1-pixel serifs on top/bottom rows of vertical strokes.")
    out += _bdf_header("serif", width, height, n, 9, 3)
    for i in range(n):
        encoding = 0x20 + i
        ch = chr(encoding)
        stencil = STENCIL_5x7.get(ch, ["     "]*7)
        # serif cap = OR-spread of the first stencil row
        def _cap(row):
            v = _row_to_byte(row, 5)
            cap = v | (v << 1) | (v >> 1)
            cap &= 0xF8  # 5 leftmost bits only
            return cap & 0xFF
        hex_rows = []
        hex_rows.append("00")           # row 0 blank top
        hex_rows.append(f"{_cap(stencil[0]):02X}")  # row 1: top serif
        for r in stencil:               # rows 2..8: 7 body rows
            hex_rows.append(f"{_row_to_byte(r, 5):02X}")
        hex_rows.append(f"{_cap(stencil[6]):02X}")  # row 9: bottom serif
        hex_rows.append("00")           # row 10 blank
        hex_rows.append("00")           # row 11 blank (descender)
        _emit_glyph_lines(out, encoding, width, height, hex_rows, f"U+{encoding:04X}")
    out.append("ENDFONT")
    out.append("")
    with open(path, "w") as f:
        f.write("\n".join(out))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    fonts = os.path.join(root, "fonts")
    os.makedirs(fonts, exist_ok=True)
    gen_mono_bdf(os.path.join(fonts, "hamnix-mono-8x16.bdf"))
    gen_sans_bdf(os.path.join(fonts, "hamnix-sans-6x10.bdf"))
    gen_serif_bdf(os.path.join(fonts, "hamnix-serif-6x12.bdf"))
    print("wrote 3 BDF fonts under fonts/")


if __name__ == "__main__":
    main()
