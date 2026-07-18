#!/usr/bin/env bash
# scripts/test_hambrowse_decimlen_host.sh — FAST, QEMU-free gate for FRACTIONAL
# / decimal CSS lengths in the native browser engine (lib/web/css/cascade.ad).
#
# The existing cssvalues gate covers rem/calc/var()/min-max-clamp with INTEGER
# operands only. This gate pins the fractional-precision path that nearly every
# modern design system depends on and that an integer-only length scanner
# silently truncates at the '.':
#
#   * padding: 0.75rem  -> 12px  (0.75 * 16px root-em). A truncating scanner
#     reads 0rem -> padding 0, so the box's left edge would sit at x=100 (the
#     content margin) instead of x=112.
#   * width: 33.3%      -> a width strictly WIDER than an integer 33% (which
#     truncation would produce). 33% -> right edge 308; 33.3% -> 310.
#   * width: 25.5%      -> a fractional percentage distinct from 25%.
#   * font-size:1.5rem / 1.5em -> 24px headings that parse (the host preview is
#     monospace and cannot depict glyph scaling — see feedback_host_preview_
#     monospace_lies — so size is proven by the pixel-accurate length math
#     above, not by glyph width; here we only assert the styled box renders).
#
# Rendered through the frozen Python seed compiler (no QEMU), and the native
# hambrowse target is also compiled so a break in either backend fails here.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_decimlen.html"
mkdir -p "$OUT"

echo "[hb-decimlen] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/decimlen_compile.log"; then
    echo "[hb-decimlen] FAIL: host harness did not compile"; cat "$OUT/decimlen_compile.log"; exit 1
fi
echo "[hb-decimlen] PASS host harness compiled -> $BIN"

DUMP="$OUT/decimlen_dump.txt"
if ! "$BIN" "$FIX" 800 >"$DUMP" 2>&1; then
    echo "[hb-decimlen] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^FILL|^SEG ' "$DUMP" | grep -Ei 'ffcc00|33aa33|2255aa|cc00cc|eeeeee' || true

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-decimlen] PASS $msg"
    else
        echo "[hb-decimlen] FAIL $msg  (/$pat/)"; fail=1
    fi
}

# Layout produced content.
assert_grep 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* ' "layout produced segments/rows"

# --- 0.75rem padding -> 12px left edge (fractional rem) ---------------
# Integer truncation reads 0rem: the box would start at x=100, not x=112.
assert_grep '^FILL 5 6 112 328 #ffcc00'  "padding:0.75rem -> 12px left padding (x=112, not 100)"

# --- 33.3% width -> right edge WIDER than an integer 33% (=308) -------
assert_grep '^FILL 7 9 100 310 #33aa33'  "width:33.3% -> 310px right edge (33% would be 308)"

# --- 25.5% width -> a fractional percentage box ----------------------
assert_grep '^FILL 11 13 100 264 #2255aa'  "width:25.5% -> 264px right edge (fractional %)"

# --- decimal em/rem font-size boxes render (value path exercised) ----
assert_grep '^SEG 0 108 #[0-9a-f]+ b1 u0 s0 l-1 bg#eeeeee .Heading at 1.5rem.' \
    "font-size:1.5rem heading renders (bold, tinted bg)"
assert_grep '^SEG [0-9]+ 108 #[0-9a-f]+ b0 u0 s0 l-1 bg#cc00cc .Text at 1.5em.' \
    "font-size:1.5em paragraph renders"

echo "[hb-decimlen] compiling native hambrowse for x86_64-adder-user (no regress) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/decimlen_native.log"; then
    echo "[hb-decimlen] FAIL: native hambrowse did not compile"; cat "$OUT/decimlen_native.log"; exit 1
fi
echo "[hb-decimlen] PASS native hambrowse still compiles"

if [ "$fail" = 0 ]; then
    echo "[hb-decimlen] RESULT: PASS"; exit 0
else
    echo "[hb-decimlen] RESULT: FAIL"; exit 1
fi
