#!/usr/bin/env bash
# scripts/test_hamcalc_host.sh — FAST, QEMU-free host gate for the calculator
# scene app (lib/hamcalccore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_ham2048_host.sh: compiles the core
# for the x86_64-linux host target, renders the scene to a PNG a human/agent
# can LOOK at, drives SCRIPTED keyboard + pointer input, asserts the
# arithmetic result, AND confirms the NATIVE Hamnix build still compiles from
# the same core — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamcalc_host"
mkdir -p "$OUT"
fail=0

echo "[calc-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamcalcscene_host.ad -o "$BIN" 2>"$OUT/calc_compile.log"; then
    echo "[calc-host] FAIL: host harness did not compile"; cat "$OUT/calc_compile.log"; exit 1
fi
echo "[calc-host] PASS host harness compiled -> $BIN"

echo "[calc-host] compiling NATIVE hamcalcscene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamcalcscene.ad -o "$OUT/hamcalc_native.elf" 2>"$OUT/calc_native.log"; then
    echo "[calc-host] FAIL: native hamcalcscene did not compile"; cat "$OUT/calc_native.log"; exit 1
fi
echo "[calc-host] PASS native hamcalcscene still compiles"

echo "[calc-host] running host harness (expression 7*6=) ..."
DUMP="$OUT/calc_dump.txt"
BEFORE="$OUT/calc_before.ppm"
AFTER="$OUT/calc_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" "7*6=" >"$DUMP" 2>&1; then
    echo "[calc-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/calc_$f.ppm" "$OUT/calc_$f.png" 2>"$OUT/calc_png.log"; then
        echo "[calc-host] PASS rendered $OUT/calc_$f.png ($(file -b "$OUT/calc_$f.png" 2>/dev/null))"
    else
        echo "[calc-host] FAIL png conversion ($f)"; cat "$OUT/calc_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[calc-host] PASS $msg"
    else
        echo "[calc-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 188 248 #2b2f36'         "calculator case background"
assert_grep '^fill 8 8 172 41 #0d1410'          "sunken LCD display bar"
assert_grep '^glyphs 164 22 \"0\" #9ff09f'      "display shows 0 in LCD green, right-aligned"
assert_grep '^fill 8 58 40 42 #c8c4bc'          "top-left key face geometry"
assert_grep '^glyphs 24 75 \"7\" #202020'       "digit '7' key label in dark"
assert_grep '^glyphs 156 75 \"/\" #7a2a00'      "operator '/' key label in orange"
assert_grep '^glyphs 24 213 \"C\" #7a0000'      "clear 'C' key label in red"
assert_grep '^glyphs 112 213 \"=\" #7a2a00'     "equals '=' key label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([4-9][0-9])'               "rasterizer drew the scene primitives"
assert_grep '^PIX 2 2 #2b2f36'                  "raster case pixel = dark slate"
assert_grep '^PIX 20 20 #0d1410'                "raster LCD pixel = dark green-black"
assert_grep '^PIX 20 70 #c8c4bc'                "raster key-face pixel = button grey"

# --- Initial state -------------------------------------------------------
assert_grep '^DISPLAY0 0'                        "initial display is 0"

# --- Scripted keyboard input computes an arithmetic result ---------------
assert_grep '^ACC_KBD 42'                        "keyboard '7*6=' computes 42"
assert_grep '^DISPLAY1 42'                        "display shows the result 42"

# --- Scripted pointer input hit-tests + clears ---------------------------
assert_grep '^KEYAT 28 208 12'                   "pointer press hit-tests the 'C' (clear) key (index 12)"
assert_grep '^ACC_AFTER_C 0'                     "clicking 'C' clears the accumulator to 0"
assert_grep '^ERR 0'                             "no error latched"

if [ "$fail" -eq 0 ]; then
    echo "[calc-host] RESULT: PASS"
    exit 0
else
    echo "[calc-host] RESULT: FAIL"
    exit 1
fi
