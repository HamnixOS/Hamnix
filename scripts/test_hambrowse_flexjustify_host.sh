#!/usr/bin/env bash
# scripts/test_hambrowse_flexjustify_host.sh — FAST, QEMU-free gate for the
# round-4 web-standards rung in the native browser engine (lib/htmlengine.ad):
# REAL flex free-space distribution + the flex-list container box/indent.
#
#   (1) justify-content on a `display:flex` row with NARROW items now uses each
#       child's NATURAL content width and distributes the free space, instead of
#       the old equal-column approximation that rendered every value identically:
#         flex-start   -> items packed at the left edge
#         center       -> the item group centred in the row
#         flex-end     -> items packed at the right edge
#         space-between-> first item flush left, last flush right
#         space-around -> equal space around each item (leading margin < center)
#       This is the single largest remaining flex win — it affects the majority
#       of real flex layouts (nav bars, button/chip rows, toolbars).
#
#   (2) A flex `<ul style="display:flex;background:…">` now opens its OWN
#       container box, so the list's background/border paints as a full-width bar
#       over the whole flex row (a bare <ul>, unlike <div>/<nav>, previously
#       opened no box and dropped the bar).
#
#   (3) A flex <ul>/<ol> resets its LIST_STEP left padding: the navbar sits FLUSH
#       at the content edge instead of indented one list level.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexjust] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexjust] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexjust] PASS host harness compiled -> $BIN"

echo "[hb-flexjust] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexjust] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexjust] PASS native hambrowse still compiles"

fail=0

# ---- (1) justify-content distribution -------------------------------------
DJ="$OUT/flexjustify.txt"
"$BIN" tests/fixtures/hambrowse_flexjustify.html 800 >"$DJ" 2>&1 \
    || { echo "[hb-flexjust] FAIL: justify render exited non-zero"; cat "$DJ"; exit 1; }

# "One"/"Three" appear once per variant, in document order:
#   [0] flex-start  [1] center  [2] flex-end  [3] space-between  [4] space-around
mapfile -t ONEX   < <(grep -E 'SEG [0-9]+ [0-9]+ .*\|One\|'   "$DJ" | awk '{print $3}')
mapfile -t THREEX < <(grep -E 'SEG [0-9]+ [0-9]+ .*\|Three\|' "$DJ" | awk '{print $3}')

if [ "${#ONEX[@]}" -lt 5 ] || [ "${#THREEX[@]}" -lt 5 ]; then
    echo "[hb-flexjust] FAIL: expected 5 flex rows, got One=${#ONEX[@]} Three=${#THREEX[@]}"
    grep -E '\|One\||\|Three\|' "$DJ"; exit 1
fi
echo "[hb-flexjust] One x by variant: start=${ONEX[0]} center=${ONEX[1]} end=${ONEX[2]} between=${ONEX[3]} around=${ONEX[4]}"
echo "[hb-flexjust] Three x by variant: start=${THREEX[0]} center=${THREEX[1]} end=${THREEX[2]} between=${THREEX[3]} around=${THREEX[4]}"

# flex-start: first item flush left AND the group packed tight (natural widths).
if [ "${ONEX[0]}" -lt 150 ] && [ "$(( THREEX[0] - ONEX[0] ))" -lt 120 ]; then
    echo "[hb-flexjust] PASS flex-start packs items left (One=${ONEX[0]} Three=${THREEX[0]})"
else
    echo "[hb-flexjust] FAIL flex-start did not pack left (One=${ONEX[0]} Three=${THREEX[0]})"; fail=1
fi
# center: the item group is centred (first item well right of flush-left, well
# left of flush-right).
if [ "${ONEX[1]}" -gt 250 ] && [ "${ONEX[1]}" -lt 500 ]; then
    echo "[hb-flexjust] PASS center centres the item group (One=${ONEX[1]})"
else
    echo "[hb-flexjust] FAIL center not centred (One=${ONEX[1]})"; fail=1
fi
# flex-end: items packed at the right edge.
if [ "${ONEX[2]}" -gt 450 ]; then
    echo "[hb-flexjust] PASS flex-end packs items right (One=${ONEX[2]})"
else
    echo "[hb-flexjust] FAIL flex-end did not pack right (One=${ONEX[2]})"; fail=1
fi
# space-between: first item flush left, last item flush right.
if [ "${ONEX[3]}" -lt 150 ] && [ "${THREEX[3]}" -gt 550 ]; then
    echo "[hb-flexjust] PASS space-between spreads first-left/last-right (One=${ONEX[3]} Three=${THREEX[3]})"
else
    echo "[hb-flexjust] FAIL space-between wrong (One=${ONEX[3]} Three=${THREEX[3]})"; fail=1
fi
# space-around: a leading margin (not flush left) but less than center's offset.
if [ "${ONEX[4]}" -gt 150 ] && [ "${ONEX[4]}" -lt "${ONEX[1]}" ]; then
    echo "[hb-flexjust] PASS space-around leaves margins around items (One=${ONEX[4]})"
else
    echo "[hb-flexjust] FAIL space-around wrong (One=${ONEX[4]} center=${ONEX[1]})"; fail=1
fi
# the five variants must NOT all coincide (the old equal-column bug rendered
# every value identically).
if [ "${ONEX[0]}" != "${ONEX[2]}" ] && [ "${ONEX[1]}" != "${ONEX[2]}" ]; then
    echo "[hb-flexjust] PASS justify-content values render DISTINCTLY (no equal-column collapse)"
else
    echo "[hb-flexjust] FAIL justify-content values collapsed to one layout"; fail=1
fi

# ---- (2)+(3) flex <ul> container box + flush indent ------------------------
DL="$OUT/flexlist.txt"
"$BIN" tests/fixtures/hambrowse_flexlist.html 800 >"$DL" 2>&1 \
    || { echo "[hb-flexjust] FAIL: flexlist render exited non-zero"; cat "$DL"; exit 1; }

# (2) the flex <ul style="background:#2b3a55"> paints a full-width background bar.
if grep -Eq 'FILL [0-9]+ [0-9]+ 1[0-9][0-9] 7[0-9][0-9] #2b3a55' "$DL"; then
    echo "[hb-flexjust] PASS flex <ul> paints its own background bar (gap #3)"
else
    echo "[hb-flexjust] FAIL flex <ul> background bar missing"; grep -E 'FILL' "$DL"; fail=1
fi
# (3) the flex list's items sit FLUSH (content-left ~108), not indented (~140).
hx=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|Home\|' "$DL" | awk '{print $3}' | head -1)
echo "[hb-flexjust] flex <li> Home x=$hx"
if [ -n "$hx" ] && [ "$hx" -le 120 ]; then
    echo "[hb-flexjust] PASS flex <ul>/<li> resets list indent — navbar flush (gap #4, Home=$hx)"
else
    echo "[hb-flexjust] FAIL flex list not flush (Home=$hx, expected <=120)"; fail=1
fi
# control: the flex <li> text keeps its cascaded colour (white on the dark bar).
if grep -Eq 'SEG [0-9]+ [0-9]+ #ffffff .*\|Home\|' "$DL"; then
    echo "[hb-flexjust] PASS flex <li> keeps its cascaded text colour"
else
    echo "[hb-flexjust] FAIL flex <li> lost its colour"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexjust] RESULT: FAIL"; exit 1
fi
echo "[hb-flexjust] RESULT: PASS"
