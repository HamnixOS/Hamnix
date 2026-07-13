#!/usr/bin/env bash
# scripts/test_hambrowse_nesttable.sh — FAST, QEMU-free gate proving hambrowse
# lays out and strokes NESTED tables: a <table> inside another table's <td> is
# laid out as its own table box within the parent cell, recursing to arbitrary
# depth, and EACH table's border strokes as a real 1px pixel rectangle (via the
# same border-box registry the CSS-border work introduced) — not just the outer.
#
# Before this, the engine had a single flat table context: a nested <table>
# clobbered the outer table's column model and the inner </table> reset
# table_active, so the remaining outer cells collapsed to plain flow and only
# the outer (if any) border was ever considered. Now lib/htmlengine pushes/pops
# a per-table context stack and registers a bbox per bordered table.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each stroked border rect
# and SAMPLES the framebuffer (edge dark #000000, padding just inside white).
# This gate asserts:
#   * the nested fixture strokes >= 2 border rectangles (inner + outer);
#   * the inner rect is INSET strictly inside the outer rect (real containment);
#   * every sampled border edge is a solid dark stroke;
#   * CONTROL: the same table WITHOUT the inner <table> strokes exactly ONE
#     border — so the extra rectangle is proof of real nesting, not a tautology
#     (depth matters).
#
# Built with the frozen Python seed compiler; PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-nest] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/nest_compile.log"; then
    echo "[hb-nest] FAIL: driver did not compile"; cat "$OUT/nest_compile.log"; exit 1
fi
echo "[hb-nest] PASS pixel backend compiled"

echo "[hb-nest] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/nest_native.log"; then
    echo "[hb-nest] FAIL: native hambrowse did not compile"; cat "$OUT/nest_native.log"; exit 1
fi
echo "[hb-nest] PASS native hambrowse still compiles"

# --- (A) NESTED table: >= 2 borders, inner strictly inside outer -------------
FIX="tests/fixtures/hambrowse_nesttable.html"
DUMP="$OUT/nest_dump.txt"
PPM="$OUT/nest.ppm"
PNG="$OUT/nest.png"
echo "[hb-nest] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-nest] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-nest] wrote $PNG"
grep -E '^BORDER' "$DUMP"

NB=$(awk '/^BORDER n / {print $3; exit}' "$DUMP")
if [ "${NB:-0}" -ge 2 ]; then
    echo "[hb-nest] PASS nested table strokes >= 2 border rectangles (n=$NB)"
else
    echo "[hb-nest] FAIL expected >= 2 borders (inner + outer), got n=${NB:-0}"; fail=1
fi

# Every sampled border edge must be a dark stroke (real drawn line).
BADEDGE=$(awk '/^BORDER [0-9]/ {for(i=1;i<=NF;i++) if($i=="edge" && $(i+1)!="#000000") c++} END{print c+0}' "$DUMP")
if [ "${BADEDGE:-1}" -eq 0 ]; then
    echo "[hb-nest] PASS every nested-table border edge is a solid dark stroke"
else
    echo "[hb-nest] FAIL $BADEDGE border edge(s) were not dark strokes"; fail=1
fi

# Border 0 registers first = the innermost table; the highest index = outer.
# Assert the inner rectangle is strictly INSET within the outer one.
read IX0 IY0 IX1 IY1 < <(awk '/^BORDER 0 / {for(i=1;i<=NF;i++){if($i=="x0")a=$(i+1);if($i=="y0")b=$(i+1);if($i=="x1")c=$(i+1);if($i=="y1")d=$(i+1)} print a,b,c,d; exit}' "$DUMP")
read OX0 OY0 OX1 OY1 < <(awk -v n="$NB" '$1=="BORDER" && $2==(n-1) {for(i=1;i<=NF;i++){if($i=="x0")a=$(i+1);if($i=="y0")b=$(i+1);if($i=="x1")c=$(i+1);if($i=="y1")d=$(i+1)} print a,b,c,d; exit}' "$DUMP")
echo "[hb-nest] inner rect=($IX0,$IY0)-($IX1,$IY1)  outer rect=($OX0,$OY0)-($OX1,$OY1)"
if [ -n "${IX0:-}" ] && [ -n "${OX0:-}" ] \
   && [ "$IX0" -ge "$OX0" ] && [ "$IX1" -le "$OX1" ] \
   && [ "$IY0" -gt "$OY0" ] && [ "$IY1" -lt "$OY1" ]; then
    echo "[hb-nest] PASS inner table border is inset strictly inside the outer cell"
else
    echo "[hb-nest] FAIL inner border not contained within the outer border"; fail=1
fi

# --- (B) CONTROL: the same table WITHOUT the inner <table> => exactly 1 border -
FIX2="tests/fixtures/hambrowse_nesttable_flat.html"
DUMP2="$OUT/nest_flat_dump.txt"
PPM2="$OUT/nest_flat.ppm"
echo "[hb-nest] rendering control $FIX2 (no nested table) ..."
"$BIN" "$FIX2" "$PPM2" 640 >"$DUMP2" 2>&1
grep -E '^BORDER n' "$DUMP2"
NB2=$(awk '/^BORDER n / {print $3; exit}' "$DUMP2")
if [ "${NB2:-0}" -eq 1 ]; then
    echo "[hb-nest] PASS un-nested control strokes exactly 1 border — depth matters"
else
    echo "[hb-nest] FAIL control expected exactly 1 border, got n=${NB2:-0}"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-nest] RESULT: PASS"
else
    echo "[hb-nest] RESULT: FAIL"; exit 1
fi
