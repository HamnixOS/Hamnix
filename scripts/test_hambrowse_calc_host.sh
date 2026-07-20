#!/usr/bin/env bash
# scripts/test_hambrowse_calc_host.sh — FAST, QEMU-free gate for CSS calc()
# expression evaluation in the native browser engine
# (lib/web/css/cascade.ad: _calc_expr / _calc_term / _calc_factor / _calc_var,
# reached from _style_len). calc() resolves each operand through the existing
# unit machinery (_len_apply_unit), applies correct operator precedence
# (* / before + -), honours parentheses, and — this gate's new coverage —
# substitutes var() INSIDE calc(). Each case is pinned to a concrete resolved
# pixel span so an arithmetic/precedence/unit/var regression fails HERE without
# a QEMU boot.
#
# Rendered at WIDTH=800 (bw), HEIGHT=600 (bh); content column = 584px, x0=100,
# x1 = 100 + resolved-width + 16 chrome:
#   calc(100px + 50px)     -> 150px -> x1 266  (fixed sum)
#   calc(100% - 40px)      -> 544px -> x1 660  (percentage arithmetic; 584-40)
#   calc(10px * 3)         -> 30px  -> x1 146  (multiply by unitless)
#   calc(2rem + 10px)      -> 42px  -> x1 158  (rem=16 -> 32 + 10)
#   calc(10px + 2px * 5)   -> 20px  -> x1 136  (precedence: * before +)
#   calc((10px + 2px) * 2) -> 24px  -> x1 140  (parens override precedence)
#   calc(50vw - 100px)     -> 300px -> x1 416  (viewport unit inside calc)
#   calc(100% - var(--g))  -> 576px -> x1 692  (var(--g:8px) inside calc; 584-8)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_calc.html"
mkdir -p "$OUT"

echo "[hb-calc] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-calc] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-calc] PASS host harness compiled -> $BIN"

echo "[hb-calc] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-calc] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-calc] PASS native hambrowse still compiles"

fail=0
D0="$OUT/calc.txt"
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-calc] PASS $2"
    else
        echo "[hb-calc] FAIL $2 (missing: $1)"; fail=1
    fi
}

"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-calc] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'FILL' "$D0" | grep -Ei '#111111|#222222|#333333|#444444|#555555|#666666|#777777|#888888' || true

assert_grep 'FILL [0-9]+ [0-9]+ 100 266 #111111'  "calc(100px + 50px) -> 150px"
assert_grep 'FILL [0-9]+ [0-9]+ 100 660 #222222'  "calc(100% - 40px) -> 544px (percentage)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 146 #333333'  "calc(10px * 3) -> 30px (multiply)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 158 #444444'  "calc(2rem + 10px) -> 42px (rem operand)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 136 #555555'  "calc(10px + 2px * 5) -> 20px (precedence)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 140 #666666'  "calc((10px + 2px) * 2) -> 24px (nested parens)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 416 #777777'  "calc(50vw - 100px) -> 300px (viewport unit)"
assert_grep 'FILL [0-9]+ [0-9]+ 100 692 #888888'  "calc(100% - var(--g)) -> 576px (var() inside calc)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-calc] RESULT: FAIL"; exit 1
fi
echo "[hb-calc] RESULT: PASS"
