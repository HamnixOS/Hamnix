#!/usr/bin/env bash
# scripts/test_hambrowse_geom_host.sh — FAST, QEMU-free gate for the DOM LAYOUT
# GEOMETRY surface (browser W3C campaign): getBoundingClientRect(),
# offsetWidth/Height/Left/Top, clientWidth/Height, offsetParent, and a basic
# getComputedStyle() (display / width). These expose the coordinates the layout
# engine already computes (the SEG display list) as the standard DOM geometry
# APIs sticky headers, dropdown/tooltip positioning, lazy-load and carousels
# rely on.
#
# The CORE PROOF is a COORDINATE CROSS-CHECK: the box getBoundingClientRect()
# reports for a known element is derived independently from the engine's SEG
# dump (row/x/text-length) and asserted to be byte-identical — proving the DOM
# geometry is sourced from the real laid-out box, not a stub.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_geom.html"
mkdir -p "$OUT"

echo "[hb-geom] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/geom_compile.log"; then
    echo "[hb-geom] FAIL: host harness did not compile"; cat "$OUT/geom_compile.log"; exit 1
fi
echo "[hb-geom] PASS host harness compiled -> $BIN"

echo "[hb-geom] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/geom_native.log"; then
    echo "[hb-geom] FAIL: native hambrowse did not compile"; cat "$OUT/geom_native.log"; exit 1
fi
echo "[hb-geom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/geom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-geom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-geom] PASS $2"
    else
        echo "[hb-geom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-geom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-geom] PASS $2"
    fi
}

# ---- COORDINATE CROSS-CHECK -------------------------------------------------
# Independently derive #a's expected box from the SEG dump line for |AlphaOne|:
#   left   = SEG x (column 3)
#   top    = SEG row (column 2) * LINE_H(16)
#   width  = len("AlphaOne") * CELL_W(8)
#   height = LINE_H(16)
SEGLINE=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|AlphaOne\|' "$D0" | head -1)
if [ -z "$SEGLINE" ]; then
    echo "[hb-geom] FAIL: no SEG line for |AlphaOne| to cross-check against"; fail=1
else
    SROW=$(echo "$SEGLINE" | awk '{print $2}')
    SX=$(echo "$SEGLINE"   | awk '{print $3}')
    EXP_TOP=$(( SROW * 16 ))
    EXP_W=$(( 8 * 8 ))   # 8 chars * CELL_W
    EXP_LINE="rect ${SX} ${EXP_TOP} ${EXP_W} 16"
    echo "[hb-geom] SEG-derived box for #a -> ${EXP_LINE}"
    assert_grep "^JSLOG ${EXP_LINE}\$" "getBoundingClientRect() x/y/width/height == the SEG-dump box"
    # right/bottom are consistent with left+width / top+height.
    EXP_RIGHT=$(( SX + EXP_W ))
    assert_grep "^JSLOG edge ${SX} ${EXP_TOP} ${EXP_RIGHT} 16\$" "left/top/right/bottom are self-consistent"
    # offset* mirror the same box; clientWidth/Height == offset here.
    assert_grep "^JSLOG off ${SX} ${EXP_TOP} ${EXP_W} 16\$" "offsetLeft/Top/Width/Height match the box"
    assert_grep "^JSLOG client ${EXP_W} 16\$"               "clientWidth/clientHeight match the box"
    assert_grep "^JSLOG awidth ${EXP_W}px\$"                "getComputedStyle().width resolves to the box width in px"
fi

# ---- getComputedStyle().display: tag-derived UA defaults --------------------
assert_grep '^JSLOG disp block$'   "getComputedStyle(div).display == block"
assert_grep '^JSLOG bdisp block$'  "getComputedStyle(p).display == block"
assert_grep '^JSLOG cdisp inline$' "getComputedStyle(span).display == inline"

# ---- offsetParent walks to the containing element ---------------------------
assert_grep '^JSLOG op wrap$'      "offsetParent resolves to the parent element (#wrap)"

# No uncaught JS error anywhere in the geometry script.
assert_nogrep '^JSERR'   "no uncaught JS error across the geometry script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing geometry API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-geom] RESULT: FAIL"; exit 1
fi
echo "[hb-geom] RESULT: PASS"
