#!/usr/bin/env bash
# scripts/test_hamctl_host.sh — FAST, QEMU-free host gate for the Control
# Center hub (lib/hamctlcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Renders the three capplet pages (Appearance / Date &
# Time / About) to PNGs a human/agent can LOOK at, drives scripted pointer
# clicks (pick a wallpaper swatch, switch category, bump the UTC offset) and
# asserts the action codes + resulting state, AND confirms the NATIVE Hamnix
# build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamctl_host"
mkdir -p "$OUT"
fail=0

echo "[ctl-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamctl_host.ad -o "$BIN" 2>"$OUT/ctl_compile.log"; then
    echo "[ctl-host] FAIL: host harness did not compile"; cat "$OUT/ctl_compile.log"; exit 1
fi
echo "[ctl-host] PASS host harness compiled -> $BIN"

echo "[ctl-host] compiling NATIVE hamctl for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamctl.ad -o "$OUT/hamctl_native.elf" 2>"$OUT/ctl_native.log"; then
    echo "[ctl-host] FAIL: native hamctl did not compile"; cat "$OUT/ctl_native.log"; exit 1
fi
echo "[ctl-host] PASS native hamctl still compiles"

DUMP="$OUT/ctl_dump.txt"
if ! "$BIN" "$OUT/ctl_appear.ppm" "$OUT/ctl_dt.ppm" "$OUT/ctl_display.ppm" \
        "$OUT/ctl_mouse.ppm" "$OUT/ctl_kbd.ppm" "$OUT/ctl_about.ppm" >"$DUMP" 2>&1; then
    echo "[ctl-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in appear dt display mouse kbd about; do
    if python3 scripts/ppm_to_png.py "$OUT/ctl_$f.ppm" "$OUT/ctl_$f.png" 2>"$OUT/ctl_png.log"; then
        echo "[ctl-host] PASS rendered $OUT/ctl_$f.png"
    else
        echo "[ctl-host] FAIL png conversion ($f)"; cat "$OUT/ctl_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[ctl-host] PASS $2";
    else echo "[ctl-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- Appearance page ---
assert_grep '^glyphs 10 8 \"Control Center\"'      "hub title bar"
assert_grep '^glyphs 152 40 \"Desktop Wallpaper\"' "Appearance page heading"
assert_grep '^ACT_SWATCH 2'                         "swatch click returns ACT_WALL(2)"
assert_grep '^SEL_SWATCH 3'                         "picked swatch index 3"
# --- Date & Time page ---
assert_grep '^ACT_CAT_DT 1'                         "sidebar switched to Date & Time (ACT_CAT)"
assert_grep '^glyphs .*\"Date & Time\"'             "Date & Time heading"
assert_grep 'Sun Jul 12  14:30'                     "current date/time rendered"
assert_grep '^ACT_TZ 3'                             "UTC +/- returns ACT_TZ(3)"
assert_grep '^TZ_OFF 2'                             "two + clicks -> UTC+2"
# --- Display page (framebuffer read-out + UI-scale stepper) ---
assert_grep '^ACT_CAT_DISP 1'                       "sidebar switched to Display (ACT_CAT)"
assert_grep '^glyphs .*\"Display\"'                 "Display heading"
assert_grep '^glyphs .*\"1024x768\"'                "resolution read-out rendered"
assert_grep '^glyphs .*\"32-bit\"'                  "colour depth read-out rendered"
assert_grep '^glyphs .*\"4096 B/row\"'              "stride read-out rendered"
assert_grep '^ACT_DISP 4'                           "scale stepper returns ACT_DISPLAY(4)"
assert_grep '^DISP_SCALE 2'                         "UI scale bumped 1x -> 2x"
assert_grep '^glyphs .*\"2x\"'                      "scale value rendered after bump"
# --- Mouse page (speed + primary button + scroll direction) ---
assert_grep '^ACT_CAT_MOUSE 1'                      "sidebar switched to Mouse (ACT_CAT)"
assert_grep '^glyphs .*\"Pointer speed:\"'          "Mouse pointer-speed row"
assert_grep '^ACT_MOUSE 5'                          "mouse control returns ACT_MOUSE(5)"
assert_grep '^MS_SPEED 6'                           "pointer speed bumped 5 -> 6"
assert_grep '^MS_PRIMARY 1'                         "primary button set to Right"
assert_grep '^MS_NATURAL 1'                         "scroll set to Natural"
assert_grep '^glyphs .*\"Natural\"'                 "Natural toggle rendered"
# --- Keyboard page (repeat delay/rate + layout read-out) ---
assert_grep '^ACT_CAT_KBD 1'                        "sidebar switched to Keyboard (ACT_CAT)"
assert_grep '^glyphs .*\"Repeat delay:\"'           "Keyboard repeat-delay row"
assert_grep '^ACT_KBD 6'                            "kbd control returns ACT_KBD(6)"
assert_grep '^KB_DELAY 550'                         "repeat delay bumped 500 -> 550ms"
assert_grep '^KB_RATE 22'                           "repeat rate bumped 20 -> 22/s"
assert_grep '^glyphs .*\"us\"'                      "keyboard layout read-out rendered"
# --- About page ---
assert_grep '^ACT_CAT_ABOUT 1'                      "sidebar switched to About"
assert_grep '^ABOUT_N 7'                            "seven About facts populated"
assert_grep '^glyphs .*\"About This System\"'       "About heading"
assert_grep 'glyphs .*\"hamnix\"'                   "hostname value rendered"
assert_grep 'glyphs .*\"2048 MB\"'                  "memory value rendered"
# --- rasterizer sanity ---
assert_grep '^PIX 4 4 #3a6ea5'                      "raster title-bar pixel = blue"

if [ "$fail" -ne 0 ]; then echo "[ctl-host] OVERALL FAIL"; exit 1; fi
echo "[ctl-host] OVERALL PASS"
