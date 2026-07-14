#!/usr/bin/env bash
# scripts/test_hambrowse_inlbpad_host.sh — FAST, QEMU-free gate for the round-7
# modern-layout rung in the native browser engine (lib/htmlengine.ad):
#
#   inline-block VERTICAL PADDING. An inline-block chip/badge/button with top+
#   bottom padding grows into a real multi-row BOX (its background FILL spans the
#   padded height and its text line is centred within it) instead of being one
#   text-line tall. Following content clears the taller box. This makes badges /
#   pills / buttons read as real controls, not one-line spans.
#
# The fixture has padded badges (`padding:12px 10px` -> 16px line + 24px padding =
# 40px = 3 rows at LINE_H=16) and flat control chips (no vertical padding -> 1 row).
# We assert the padded box FILL is 3 rows tall, the flat FILL is 1 row, and the
# following flat line CLEARS the tall badges (no overlap).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_inlbpad.html"
mkdir -p "$OUT"

echo "[hb-inlbpad] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-inlbpad] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-inlbpad] PASS host harness compiled -> $BIN"

echo "[hb-inlbpad] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-inlbpad] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-inlbpad] PASS native hambrowse still compiles"

fail=0
D="$OUT/inlbpad.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-inlbpad] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# ---- (1) padded badge (#cc3355) paints a 3-row-tall box FILL -----------------
bh=0
while read -r t b lx rx col; do
    [ "$col" = "#cc3355" ] && bh=$((b - t))
done < <(grep -E '^FILL ' "$D" | awk '{print $2, $3, $4, $5, $6}')
echo "[hb-inlbpad] padded badge FILL height = $bh rows (expect 3)"
if [ "$bh" -eq 3 ]; then
    echo "[hb-inlbpad] PASS vertical padding grows the badge box to 3 rows"
else
    echo "[hb-inlbpad] FAIL badge box not 3 rows tall (got $bh)"; grep '#cc3355' "$D" | grep FILL; fail=1
fi

# ---- (2) control chip with NO vertical padding stays 1 row (zero-cost) -------
fh=0
while read -r t b lx rx col; do
    [ "$col" = "#22aa66" ] && fh=$((b - t))
done < <(grep -E '^FILL ' "$D" | awk '{print $2, $3, $4, $5, $6}')
echo "[hb-inlbpad] flat chip FILL height = $fh rows (expect 1)"
if [ "$fh" -eq 1 ]; then
    echo "[hb-inlbpad] PASS a chip without vertical padding is unchanged (1 row)"
else
    echo "[hb-inlbpad] FAIL flat chip height changed (got $fh, expected 1)"; fail=1
fi

# ---- (3) the following flat line CLEARS the tall badges (no overlap) ---------
# padded badges occupy rows [0,3); the flat tags line must start at row >= 3.
seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
badge_top=$(seg_row "Live")
flat_row=$(seg_row "alpha")
echo "[hb-inlbpad] badges start row=$badge_top ; flat tags line row=$flat_row (must be >= 3)"
if [ -n "$flat_row" ] && [ "$flat_row" -ge 3 ]; then
    echo "[hb-inlbpad] PASS content after tall badges clears the reserved box rows"
else
    echo "[hb-inlbpad] FAIL flat line overlaps the tall badges (row=$flat_row)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-inlbpad] RESULT: FAIL"; exit 1
fi
echo "[hb-inlbpad] RESULT: PASS"
