#!/usr/bin/env bash
# scripts/test_hambrowse_fullwidth_host.sh — FAST, QEMU-free render-to-PNG gate
# for the READABLE-MEASURE SCOPING fix (lib/web/state.ad + lib/web/layout/flow.ad).
#
# THE BUG: the engine capped EVERY page's content to a 584px readable-measure
# column CENTRED in the window (MEASURE_MAX + _page_gutter). Real websites — whose
# chrome is a full-bleed nav bar and whose body is a multi-column flex/grid — then
# rendered as a narrow strip floating in the middle of a wide window, nothing like
# Firefox/Chrome, which render the body at the FULL viewport width and let the
# page's own CSS narrow any column.
#
# THE FIX (scoped, not a blanket removal): the readable-measure gutter is kept for
# a plain-prose page (bare <p>/<h*> text with no author layout) so long lines stay
# comfortable, but is DISABLED for any page that establishes an author layout
# context — display:flex / display:grid / position:absolute|fixed — so a real
# website spans the whole window edge-to-edge like a real browser.
#
# This gate pixel-asserts BOTH halves of that contract at a wide (1000px) window:
#   (A) FULL-WIDTH: a display:flex page's full-bleed nav bar background spans the
#       whole window (NOT a 584px centred strip), and its 3-card flex row fills
#       the width with the rightmost card near the right edge.
#   (B) READABLE: a plain unstyled <p>-only page STILL caps + centres its text at
#       the ~584px readable measure (a left gutter, and a right edge well short of
#       the window edge) — proving the fix did not regress plain prose.
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
SITE="tests/fixtures/hambrowse_fullwidth_site.html"
PROSE="tests/fixtures/hambrowse_fullwidth_prose.html"
W=1000
mkdir -p "$OUT"
fail=0

echo "[hb-fw] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$GFX" 2>"$OUT/fw_gfx.log"; then
    echo "[hb-fw] FAIL: pixel backend did not compile"; cat "$OUT/fw_gfx.log"; exit 1
fi
echo "[hb-fw] PASS pixel backend compiled -> $GFX"

# The native browser shares the engine; keep it compiling.
echo "[hb-fw] confirming native hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/fw_native.elf" 2>"$OUT/fw_native.log"; then
    echo "[hb-fw] FAIL: native hambrowse did not compile"; cat "$OUT/fw_native.log"; exit 1
fi
echo "[hb-fw] PASS native hambrowse still compiles"

pass() { echo "[hb-fw] PASS $1"; }
bad()  { echo "[hb-fw] FAIL $1"; fail=1; }

# POSFILL rects whose paint colour == $2 in dump $1 -> lines "x0 x1".
boxes_for() {
    awk -v c="#$2" '$1=="POSFILL"{x0="";x1="";col="";
        for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);else if($i=="x1")x1=$(i+1);
        else if($i=="col")col=$(i+1)} if(col==c)print x0, x1}' "$1"
}

# ============================================================================
# (A) FULL-WIDTH: a display:flex page spans the whole window.
# ============================================================================
SD="$OUT/fw_site.txt"
echo "[hb-fw] rendering $SITE at width $W ..."
if ! "$GFX" "$SITE" "$OUT/fw_site.ppm" "$W" >"$SD" 2>&1; then
    echo "[hb-fw] FAIL: site render exited non-zero"; cat "$SD"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/fw_site.ppm" "$OUT/fw_site.png" >/dev/null 2>&1 \
    && echo "[hb-fw] wrote $OUT/fw_site.png"

# The full-bleed nav bar background (#16324f) must span nearly the whole 1000px
# window — a left edge near 0 and a right edge near 1000 — NOT the 208..792 strip
# the old 584px readable gutter would have produced.
read -r NX0 NX1 <<<"$(boxes_for "$SD" 16324f | head -1)"
if [ -n "$NX0" ] && [ -n "$NX1" ]; then
    NW=$((NX1 - NX0))
    if [ "$NX0" -le 40 ] && [ "$NX1" -ge 950 ] && [ "$NW" -ge 900 ]; then
        pass "full-bleed nav spans the window (x=${NX0}..${NX1}, w=${NW}px >= 900, not a 584 strip)"
    else
        bad "nav bar not full-bleed (x=${NX0}..${NX1}, w=${NW}px; expected ~0..1000)"
    fi
else
    bad "nav bar background (#16324f) not found in paint stream"
fi

# The 3-card flex row (#d7e2ee) fills the width: three cards, the leftmost near
# the left edge and the rightmost near the right edge.
CARD_L=$(boxes_for "$SD" d7e2ee | awk '{print $1}' | sort -n | head -1)
CARD_R=$(boxes_for "$SD" d7e2ee | awk '{print $2}' | sort -n | tail -1)
NCARD=$(boxes_for "$SD" d7e2ee | wc -l)
if [ -n "$CARD_L" ] && [ -n "$CARD_R" ] && [ "$NCARD" -ge 3 ]; then
    if [ "$CARD_L" -le 40 ] && [ "$CARD_R" -ge 940 ]; then
        pass "3-card flex row fills the width (cards=${NCARD}, left=${CARD_L}, right=${CARD_R})"
    else
        bad "card row does not fill the width (left=${CARD_L}, right=${CARD_R}; expected ~24..~976)"
    fi
else
    bad "expected >=3 flex cards (#d7e2ee); found ${NCARD} (left=${CARD_L:-?} right=${CARD_R:-?})"
fi

# ============================================================================
# (B) READABLE: a plain unstyled prose page KEEPS the ~584px readable measure.
# ============================================================================
PD="$OUT/fw_prose.txt"
echo "[hb-fw] rendering $PROSE at width $W ..."
if ! "$GFX" "$PROSE" "$OUT/fw_prose.ppm" "$W" >"$PD" 2>&1; then
    echo "[hb-fw] FAIL: prose render exited non-zero"; cat "$PD"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/fw_prose.ppm" "$OUT/fw_prose.png" >/dev/null 2>&1 \
    && echo "[hb-fw] wrote $OUT/fw_prose.png"

# The left content margin (UAELEM ddx) must show the centring gutter (>> the bare
# 8px CONTENT_X), and the rightmost text x (REFLOW maxx) must stay well short of
# the 1000px window edge — the text column is the ~584px readable measure, centred.
DDX=$(grep -oE "ddx [0-9]+" "$PD" | head -1 | awk '{print $2}')
MAXX=$(grep -E "^REFLOW " "$PD" | awk '{for(i=1;i<=NF;i++) if($i=="maxx") print $(i+1)}' | head -1)
echo "[hb-fw] prose column: left-gutter ddx=${DDX:-?} right-edge maxx=${MAXX:-?} (window ${W}px)"
if [ -n "$DDX" ] && [ "$DDX" -ge 150 ] && [ "$DDX" -le 260 ]; then
    pass "unstyled prose keeps a centring left gutter (ddx=${DDX}px, not 8px edge-to-edge)"
else
    bad "prose left gutter wrong (ddx=${DDX:-?}; expected ~200 = 8 + (984-584)/2)"
fi
if [ -n "$MAXX" ] && [ "$MAXX" -le 810 ] && [ "$MAXX" -ge 560 ]; then
    pass "unstyled prose keeps the ~584px readable measure (right edge maxx=${MAXX}px << 1000)"
else
    bad "prose measure not capped (maxx=${MAXX:-?}; expected ~584..792, NOT near the ${W}px edge)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-fw] RESULT: FAIL"; exit 1
fi
echo "[hb-fw] RESULT: PASS"
