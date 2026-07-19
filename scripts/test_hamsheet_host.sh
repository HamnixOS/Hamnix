#!/usr/bin/env bash
# scripts/test_hamsheet_host.sh — FAST, QEMU-free host gate for HamSheet, the
# office SPREADSHEET (lib/hamsheetcore.ad drawn through lib/hamscene.ad +
# rasterized by lib/hamui_host.ad). It renders the empty grid (HamSheet title
# bar + formula bar + A/B/C… column headers + 1/2/3… row headers), enters
# numbers into A1/A2/A3 and a =SUM(A1:A3) formula into B1 (plus AVG / a cell
# arithmetic expression / MAX / COUNT), asserts the COMPUTED results, renders the
# populated grid, SAVES it (Ctrl-S -> a HAMSHEET1 container on a real scratch
# file), CLEARS the sheet, then RE-OPENS the file off disk (Ctrl-O) — proving the
# cell text AND the formulas survive a save->load round-trip and RECOMPUTE to the
# same values. Two PNGs a human/agent can LOOK at are produced, and the NATIVE
# Hamnix build is confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsheet_host"
DOC="$OUT/hamsheet_scratch.hsheet"
mkdir -p "$OUT"
rm -f "$DOC"
fail=0

echo "[hamsheet-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsheet_host.ad -o "$BIN" 2>"$OUT/hs_compile.log"; then
    echo "[hamsheet-host] FAIL: host harness did not compile"; cat "$OUT/hs_compile.log"; exit 1
fi
echo "[hamsheet-host] PASS host harness compiled -> $BIN"

echo "[hamsheet-host] compiling NATIVE hamsheet for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsheet.ad -o "$OUT/hamsheet_native.elf" 2>"$OUT/hs_native.log"; then
    echo "[hamsheet-host] FAIL: native hamsheet did not compile"; cat "$OUT/hs_native.log"; exit 1
fi
echo "[hamsheet-host] PASS native hamsheet still compiles"

DUMP="$OUT/hs_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hs_before.ppm" "$OUT/hs_after.ppm" >"$DUMP" 2>&1; then
    echo "[hamsheet-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hs_$f.ppm" "$OUT/hs_$f.png" 2>"$OUT/hs_png.log"; then
        echo "[hamsheet-host] PASS rendered $OUT/hs_$f.png"
    else
        echo "[hamsheet-host] FAIL png conversion ($f)"; cat "$OUT/hs_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamsheet-host] PASS $2";
    else echo "[hamsheet-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- window chrome / formula bar / grid headers ----------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 600 384 #dfe3e8'         "hamsheet window background"
assert_grep '^fill 0 0 600 22 #2f7d54'          "green title bar"
assert_grep 'glyphs .*"HamSheet"'               "app title label"
assert_grep 'glyphs .*"budget.hsheet"'          "filename shown in the title bar"
assert_grep 'glyphs .*"Open"'                   "Open toolbar button rendered"
assert_grep 'glyphs .*"Save"'                   "Save toolbar button rendered"
assert_grep 'glyphs .*"A" #'                    "column header A rendered"
assert_grep 'glyphs .*"B" #'                    "column header B rendered"

# --- formula engine: computed values (scaled by 10^6) ----------------------
assert_grep '^SUM_FP 60000000'                  "=SUM(A1:A3) computed 60"
assert_grep '^AVG_FP 20000000'                  "=AVG(A1:A3) computed 20"
assert_grep '^EXPR_FP 50000000'                 "=A1+A2*2 computed 50 (precedence)"
assert_grep '^MAX_FP 30000000'                  "=MAX(A1:A3) computed 30"
assert_grep '^COUNT_FP 3000000'                 "=COUNT(A1:A3) computed 3"
assert_grep '^SUM_DISP 60'                       "SUM displays as \"60\""
assert_grep '^AVG_DISP 20'                       "AVG displays as \"20\""
assert_grep '^EXPR_DISP 50'                      "expression displays as \"50\""
assert_grep '^A4_KIND 2'                         "A4 (\"Total\") classified as TEXT"
# The populated grid must actually DRAW the computed SUM value.
assert_grep 'glyphs [0-9]+ [0-9]+ "60" #'        "computed 60 drawn in the grid"
assert_grep 'glyphs [0-9]+ [0-9]+ "Total" #'     "text label \"Total\" drawn in the grid"

# --- SAVE writes a HAMSHEET1 container to disk -----------------------------
assert_grep '^FILE_LEN 1[0-9][0-9]'             "Ctrl-S wrote the document container (>=100 bytes)"

# --- CLEAR + RE-OPEN off disk: round-trip proof ----------------------------
assert_grep '^SUM_AFTER_CLEAR 0'                "sheet cleared before reopen"
assert_grep '^SUM_AFTER_OPEN 60000000'          "Ctrl-O reloaded + recomputed =SUM to 60"
assert_grep '^EXPR_AFTER_OPEN 50000000'         "the cell-arithmetic formula survived the round-trip"

# --- keyboard type-to-edit + recalc cascade --------------------------------
assert_grep '^A1_AFTER_TYPE 5000000'            "typing \"5\"+Enter set A1 to 5 via the key path"
assert_grep '^SUM_AFTER_EDIT 55000000'          "dependent =SUM(A1:A3) recalculated to 55"

# --- the reloaded B1 raw formula matches exactly ---------------------------
if awk '/^B1RAW-BEGIN$/{f=1;next} /^B1RAW-END$/{f=0} f' "$DUMP" \
        | grep -qx '=SUM(A1:A3)'; then
    echo "[hamsheet-host] PASS reloaded B1 formula is byte-exact (=SUM(A1:A3))"
else
    echo "[hamsheet-host] FAIL reloaded B1 formula mismatch"; fail=1
fi

# --- the document file really exists on disk with the magic ----------------
if [ -s "$DOC" ]; then echo "[hamsheet-host] PASS $DOC written on disk";
else echo "[hamsheet-host] FAIL document not written to $DOC"; fail=1; fi
if head -c 9 "$DOC" | grep -qx 'HAMSHEET1'; then
    echo "[hamsheet-host] PASS document carries the HAMSHEET1 magic";
else echo "[hamsheet-host] FAIL document missing HAMSHEET1 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hamsheet-host] OVERALL FAIL"; exit 1; fi
echo "[hamsheet-host] OVERALL PASS"
