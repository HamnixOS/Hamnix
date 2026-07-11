#!/usr/bin/env bash
# scripts/run_hambrowse_gfx.sh — render an HTML page to a REAL PIXEL PNG via
# the new graphical hambrowse backend (lib/htmlpaint + lib/htmlpage), so the
# "proper graphics, not an ASCII grid" improvement is VISIBLE. QEMU-free: it
# compiles the engine + pixel paint for the x86_64-linux host target and runs
# it directly, in milliseconds.
#
# USAGE:
#   scripts/run_hambrowse_gfx.sh [FILE.html] [WIDTH] [OUT.png]
# Defaults: tests/fixtures/hambrowse_article.html, width 640,
#           build/host/hambrowse_gfx_<name>.png
#
# PNG conversion uses scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FILE="${1:-tests/fixtures/hambrowse_article.html}"
WIDTH="${2:-640}"
OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx"

name="$(basename "$FILE" .html)"
PPM="$OUT/gfx_${name}.ppm"
PNG="${3:-$OUT/gfx_${name}.png}"

echo "[gfx] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/gfx_compile.log"; then
    echo "[gfx] FAIL: driver did not compile"; cat "$OUT/gfx_compile.log"; exit 1
fi

echo "[gfx] rendering $FILE (width $WIDTH) ..."
if ! "$BIN" "$FILE" "$PPM" "$WIDTH"; then
    echo "[gfx] FAIL: render exited non-zero"; exit 1
fi

if ! python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/gfx_png.log"; then
    echo "[gfx] FAIL: png conversion"; cat "$OUT/gfx_png.log"; exit 1
fi
echo "[gfx] wrote $PNG ($(file -b "$PNG" 2>/dev/null))"
