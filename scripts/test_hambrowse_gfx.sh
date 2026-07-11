#!/usr/bin/env bash
# scripts/test_hambrowse_gfx.sh — FAST, QEMU-free gate for the GRAPHICAL
# (pixel) hambrowse backend: lib/htmlpaint.ad (proportional-font canvas) +
# lib/htmlpage.ad (pixel box-model layout) driven by user/hambrowse_host_gfx.ad.
#
# The legacy scripts/test_hambrowse_host.sh asserts the OLD monospace-grid
# geometry (still valid — the parse/CSS/JS front end is unchanged). THIS gate
# asserts the NEW pixel geometry: real per-row pixel heights (an <h1> row is
# physically taller than a body row), PROPORTIONAL advance widths (narrow vs
# wide runs measure differently — impossible on a fixed 8px grid), and that a
# real RGB PNG is produced. It also confirms the NATIVE hambrowse still
# compiles from the same shared engine.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap). PNG conversion uses scripts/ppm_to_png.py (stdlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-gfx] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/gfx_compile.log"; then
    echo "[hb-gfx] FAIL: driver did not compile"; cat "$OUT/gfx_compile.log"; exit 1
fi
echo "[hb-gfx] PASS pixel backend compiled -> $BIN"

echo "[hb-gfx] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/gfx_native.log"; then
    echo "[hb-gfx] FAIL: native hambrowse did not compile"; cat "$OUT/gfx_native.log"; exit 1
fi
echo "[hb-gfx] PASS native hambrowse still compiles"

ART="tests/fixtures/hambrowse_article.html"
DUMP="$OUT/gfx_dump.txt"
PPM="$OUT/gfx_article.ppm"
PNG="$OUT/gfx_article.png"

echo "[hb-gfx] rendering $ART ..."
if ! "$BIN" "$ART" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-gfx] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/gfx_png.log"; then
    echo "[hb-gfx] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-gfx] FAIL png conversion"; cat "$OUT/gfx_png.log"; fail=1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-gfx] PASS $msg"
    else
        echo "[hb-gfx] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Both faces decoded all 95 printable glyphs.
assert_grep '^FONTS sans=95 mono=95'  "sans + mono BDF faces loaded (95 glyphs each)"

# The canvas is a real pixel bitmap wider than the grid and tall enough for the
# multi-section article (width 640; height grows with content).
assert_grep '^CANVAS 640 [0-9]{3,}'   "pixel canvas 640xN with a tall page"

# PIXEL BOX MODEL: row 0 is the <h1> — it must be physically TALLER (sans x3 =
# 30px) than the body rows below it (10px). This is the grid ceiling broken.
assert_grep '^ROW 0 top 12 h 30 base 36'  "h1 row is 30px tall (x3 heading face)"
assert_grep '^ROW 1 top 48 h 10 base 56'  "body row is 10px tall, stacked below h1"

# PROPORTIONAL TEXT: in the sans body face a narrow run (iiii) is NARROWER than
# a wide run (WWWW); in the mono face they are EQUAL. Impossible on a grid.
assert_grep '^ADV sans iiii=20 WWWW=24 mono_iiii=32 mono_WWWW=32' \
    "proportional sans advance (iiii<WWWW) vs fixed mono (equal)"

# A real framebuffer was written and the paper is white.
assert_grep '^WROTE [0-9]{6,}'        "framebuffer written to PPM"
assert_grep '^PIX 0 0 #ffffff'        "top-left pixel is white paper"

# Sanity: the CSS page renders too (centered heading via text-align).
CSS="tests/fixtures/hambrowse_css.html"
if "$BIN" "$CSS" "$OUT/gfx_css.ppm" 640 >"$OUT/gfx_css_dump.txt" 2>&1 \
        && python3 scripts/ppm_to_png.py "$OUT/gfx_css.ppm" "$OUT/gfx_css.png" 2>/dev/null; then
    echo "[hb-gfx] PASS rendered CSS page -> $OUT/gfx_css.png"
else
    echo "[hb-gfx] FAIL CSS page render"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-gfx] PASS"
else
    echo "[hb-gfx] FAIL"; exit 1
fi
