#!/usr/bin/env bash
# scripts/test_hambrowse_float.sh — FAST, QEMU-free regression for CSS `float`
# (left/right) block layout in the hambrowse engine (lib/htmlengine.ad), plus
# the page-<title> entity decode / no-script title scan.
#
# Renders tests/fixtures/hambrowse_float.html via the x86_64-linux host harness
# and asserts the STRUCTURAL properties float unlocks:
#   * a `float:right` infobox is pinned to the RIGHT of the measure (large seg x)
#     with its border + background, while the body paragraph flows on its LEFT
#     (small seg x) on the SAME rows — i.e. text wraps beside the float rather
#     than stacking below it;
#   * a `float:left` figure pushes the following paragraph's left edge to the
#     RIGHT (indented seg x) beside it;
#   * the <title> "&mdash;" entity decodes to an em dash and is exposed even
#     though the page has no <script>.
#
# Pre-fix (no float support) every block stacked full-width at the left margin,
# so the infobox text sat at the left on a row ABOVE the body — the right-side
# and indented-x assertions below fail. Post-fix they pass.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree), so
# this gate is dependency-light and needs no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_float.html"
mkdir -p "$OUT"

echo "[hb-float] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/float_compile.log"; then
    echo "[hb-float] FAIL: host harness did not compile"; cat "$OUT/float_compile.log"; exit 1
fi
echo "[hb-float] PASS host harness compiled -> $BIN"

echo "[hb-float] running host harness on $FIX ..."
DUMP="$OUT/float_dump.txt"
if ! "$BIN" "$FIX" 900 >"$DUMP" 2>&1; then
    echo "[hb-float] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-float] PASS $msg"
    else
        echo "[hb-float] FAIL $msg  (/$pat/)"; fail=1
    fi
}
refute_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-float] FAIL $msg  (/$pat/ unexpectedly present)"; fail=1
    else
        echo "[hb-float] PASS $msg"
    fi
}

# Layout produced content.
assert_grep 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* ' "layout produced segments/rows"

# --- <title> entity decode + no-script title -------------------------
assert_grep '^TITLE Float layout .* hambrowse'  "no-script page title is exposed"
refute_grep '^TITLE .*&mdash;'                   "title &mdash; entity decoded (no raw entity)"

# --- float:right infobox pinned to the RIGHT of the measure ----------
# INFOBOXTOP renders at a large seg x (>= 500 px) with the infobox background.
assert_grep '^SEG [0-9]+ (5|6|7)[0-9][0-9] #[0-9a-f]+ b1 u[0-9] s[0-9] l-1 bg#ebebd2 .INFOBOXTOP.' \
    "float:right infobox pinned to the right edge (large x) with its bg"

# --- body text wraps to the LEFT of the right float ------------------
# BODYONE flows at the left margin (x=158) on an early row that OVERLAPS the
# infobox's rows (proving beside-flow, not a stack below it).
assert_grep '^SEG 2 158 #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYONE' \
    "body paragraph flows on the LEFT of the right float, same top row"

# --- float:left figure indents the following paragraph ---------------
# FIGBOX box on the left; BODYTHREE's left edge pushed to ~x=326 beside it.
assert_grep '.FIGBOX a tabby cat.'  "float:left figure box rendered"
assert_grep '^SEG 1[0-9] (3|4)[0-9][0-9] #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYTHREE' \
    "paragraph after a float:left is indented to its RIGHT (beside it)"

echo "[hb-float] compiling native hambrowse for x86_64-adder-user (no regress) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/float_native.log"; then
    echo "[hb-float] FAIL: native hambrowse did not compile"; cat "$OUT/float_native.log"; exit 1
fi
echo "[hb-float] PASS native hambrowse still compiles"

if [ "$fail" = 0 ]; then
    echo "[hb-float] RESULT: PASS"; exit 0
else
    echo "[hb-float] RESULT: FAIL"; exit 1
fi
