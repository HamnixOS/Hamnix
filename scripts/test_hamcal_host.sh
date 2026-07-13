#!/usr/bin/env bash
# scripts/test_hamcal_host.sh — FAST, QEMU-free host gate for the Calendar
# scene app (lib/hamcalcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Compiles the core for the host target, renders the month
# grid to a PNG a human/agent can LOOK at, drives a scripted prev-month click,
# asserts the calendar math + navigation, AND confirms the NATIVE Hamnix build
# still compiles from the same core — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamcal_host"
mkdir -p "$OUT"
fail=0

echo "[cal-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamcalscene_host.ad -o "$BIN" 2>"$OUT/cal_compile.log"; then
    echo "[cal-host] FAIL: host harness did not compile"; cat "$OUT/cal_compile.log"; exit 1
fi
echo "[cal-host] PASS host harness compiled -> $BIN"

echo "[cal-host] compiling NATIVE hamcalscene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamcalscene.ad -o "$OUT/hamcal_native.elf" 2>"$OUT/cal_native.log"; then
    echo "[cal-host] FAIL: native hamcalscene did not compile"; cat "$OUT/cal_native.log"; exit 1
fi
echo "[cal-host] PASS native hamcalscene still compiles"

DUMP="$OUT/cal_dump.txt"
if ! "$BIN" "$OUT/cal_before.ppm" "$OUT/cal_after.ppm" >"$DUMP" 2>&1; then
    echo "[cal-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/cal_$f.ppm" "$OUT/cal_$f.png" 2>"$OUT/cal_png.log"; then
        echo "[cal-host] PASS rendered $OUT/cal_$f.png"
    else
        echo "[cal-host] FAIL png conversion ($f)"; cat "$OUT/cal_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[cal-host] PASS $2";
    else echo "[cal-host] FAIL $2 (missing: $1)"; fail=1; fi
}

assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 236 248 #d4d0c8'         "calendar window background"
assert_grep '^glyphs 82 38 \"July 2026\"'       "title shows the seeded month"
# 2026-07-01 is a Wednesday: day '1' lands in column 3 (x=6+3*32+10=112).
assert_grep '^glyphs 112 81 \"1\"'              "July 1 2026 placed on Wednesday"
# Today (the 12th) is highlighted white on the blue cell.
assert_grep '^glyphs 12 133 \"12\" #ffffff'     "today (12) highlighted"
assert_grep '^glyphs 172 185 \"31\"'            "last day (31) present"
assert_grep '^MONTH0 7'                         "initial month is July"
assert_grep '^PREVCLICK 1'                      "prev-month arrow consumed the click"
assert_grep '^MONTH1 6'                         "prev-month navigated July -> June"
assert_grep '^PIX 4 4 #3a6ea5'                  "raster title-bar pixel = blue"

if [ "$fail" -ne 0 ]; then echo "[cal-host] OVERALL FAIL"; exit 1; fi
echo "[cal-host] OVERALL PASS"
