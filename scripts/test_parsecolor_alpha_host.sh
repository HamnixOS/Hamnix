#!/usr/bin/env bash
# scripts/test_parsecolor_alpha_host.sh — FAST, QEMU-free host gate for the
# hamML colour parser's 8-digit "#rrggbbaa" alpha path (user/hamUId.ad
# parse_color). Regression guard for the user-reported "screenshot with a
# selected area turns the whole screen black" bug.
#
# Two-part gate:
#   1. Source guard: confirm user/hamUId.ad parse_color has an `ndig >= 8`
#      branch that sets out_a[0] from the 7th/8th hex nibbles (not 255). This
#      ties the behavioural replica below to the SHIPPED code so it can't drift.
#   2. Behaviour: compile tests/test_parsecolor_alpha_host.ad for the host and
#      assert "#00000066" -> alpha 0x66, "#ffffff22" -> 0x22, and 6-/3-digit
#      colours stay opaque (0xff).
#
# Built with the frozen Python seed compiler (no self-host bootstrap needed).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/test_parsecolor_alpha"
SRC="user/hamUId.ad"
HARNESS="tests/test_parsecolor_alpha_host.ad"
mkdir -p "$OUT"
fail=0

# --- Part 1: source guard -------------------------------------------------
echo "[parsecolor] checking $SRC has an ndig>=8 alpha branch ..."
if grep -Eq 'ndig >= 8' "$SRC" && \
   grep -Eq 'out_a\[0\] = cast\[uint8\]\(\(hex_nibble\(buf\[h0 \+ 6\]\) \* 16\) \+ hex_nibble\(buf\[h0 \+ 7\]\)\)' "$SRC"; then
    echo "[parsecolor] PASS source has the 8-digit alpha branch"
else
    echo "[parsecolor] FAIL $SRC is missing the ndig>=8 alpha branch (out_a from nibbles h0+6/h0+7)"
    fail=1
fi

# --- Part 2: compile + run behavioural replica ----------------------------
echo "[parsecolor] compiling host harness ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        "$HARNESS" -o "$BIN" 2>"$OUT/parsecolor_compile.log"; then
    echo "[parsecolor] FAIL: host harness did not compile"
    cat "$OUT/parsecolor_compile.log"
    exit 1
fi
echo "[parsecolor] PASS host harness compiled -> $BIN"

echo "[parsecolor] running host harness ..."
if ! "$BIN" >"$OUT/parsecolor_run.log" 2>&1; then
    echo "[parsecolor] FAIL: harness reported a failing assertion"
    cat "$OUT/parsecolor_run.log"
    fail=1
else
    cat "$OUT/parsecolor_run.log"
fi

if [ "$fail" -ne 0 ]; then
    echo "[parsecolor] FAIL"
    exit 1
fi
echo "[parsecolor] PASS parse_color alpha gate"
exit 0
