#!/usr/bin/env bash
# scripts/test_hamsoftware_host.sh — FAST, QEMU-free host gate for the "Software"
# app (the Synaptic-style GUI front-end over the native hpm package manager).
# The UI is lib/hampkgcore.ad drawn through lib/hamscene.ad and rasterized by
# lib/hamui_host.ad; this harness (user/hamsoftware_host.ad) feeds the pure core
# a FIXTURE package index (the exact text lines `hpm search` / `hpm list` /
# `hpm show` emit), turns the category sidebar ON, renders three PNGs a human/
# agent can LOOK at — the full list, the "Installed" category filter, and a
# selected package's detail pane — and asserts the sidebar / list / search /
# detail behaviour off the emitted scene grammar + rastered pixels. It also
# confirms the NATIVE Hamnix app (user/hamsoftware.ad) still compiles from the
# same core. hpm stays the engine; this only exercises the GUI front-end.
#
# NOTE (memory feedback_host_preview_monospace_lies): the host preview renders
# monospace and misrepresents proportional text X-positions, so we assert
# STRUCTURE / presence (which panes + labels emitted, category counts,
# hit-test results) — NOT exact caret/label pixel-X. Precise text layout is
# verified on-device / via the core's parser logic, not this PNG.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsoftware_host"
mkdir -p "$OUT"
fail=0

echo "[hamsoftware-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsoftware_host.ad -o "$BIN" 2>"$OUT/hamsoftware_compile.log"; then
    echo "[hamsoftware-host] FAIL: host harness did not compile"; cat "$OUT/hamsoftware_compile.log"; exit 1
fi
echo "[hamsoftware-host] PASS host harness compiled -> $BIN"

echo "[hamsoftware-host] compiling NATIVE hamsoftware for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsoftware.ad -o "$OUT/hamsoftware_native.elf" 2>"$OUT/hamsoftware_native.log"; then
    echo "[hamsoftware-host] FAIL: native hamsoftware did not compile"; cat "$OUT/hamsoftware_native.log"; exit 1
fi
echo "[hamsoftware-host] PASS native hamsoftware still compiles"

DUMP="$OUT/hamsoftware_dump.txt"
if ! "$BIN" "$OUT/sw_list.ppm" "$OUT/sw_cat.ppm" "$OUT/sw_detail.ppm" \
        >"$DUMP" 2>&1; then
    echo "[hamsoftware-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in list cat detail; do
    if python3 scripts/ppm_to_png.py "$OUT/sw_$f.ppm" "$OUT/sw_$f.png" 2>"$OUT/sw_png.log"; then
        echo "[hamsoftware-host] PASS rendered $OUT/sw_$f.png"
    else
        echo "[hamsoftware-host] FAIL png conversion ($f)"; cat "$OUT/sw_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamsoftware-host] PASS $2";
    else echo "[hamsoftware-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- chrome / window / non-blank frame --------------------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 772 430 #eceef2'         "widened (sidebar) window background"
assert_grep '^fill 0 0 772 30 #2f5c8f'          "blue header bar spans full width"
assert_grep 'glyphs .*\"Software\"'             "app title label is Software"
# a non-trivial primitive count proves the frame is not blank
assert_grep '^PRIMS [1-9][0-9]+'                "non-blank frame (many primitives)"
assert_grep '^PIX 4 4 3103887'                  "raster header pixel = #2f5c8f (not blank)"

# --- search field + action buttons ------------------------------------------
assert_grep 'glyphs .*\"Find\"'                 "search field label"
assert_grep 'glyphs .*\"Refresh\"'              "Refresh button"
assert_grep 'glyphs .*\"Install\"'              "Install button"
assert_grep 'glyphs .*\"Remove\"'               "Remove button"
assert_grep 'glyphs .*\"Upgrade\"'              "Upgrade button"

# --- the category sidebar (the new Synaptic left rail) ----------------------
assert_grep 'glyphs .*\"All\"'                  "sidebar: All category"
assert_grep 'glyphs .*\"Installed\"'            "sidebar: Installed category"
assert_grep 'glyphs .*\"Available\"'            "sidebar: Available category"
assert_grep 'glyphs .*\"Upgradable\"'           "sidebar: Upgradable category"

# --- package index parsed from real-shape `hpm search` output ---------------
assert_grep '^COUNT 6'                          "6 packages parsed from search output"
assert_grep '^FILT_ALL 6'                       "category All -> all 6 shown"
assert_grep 'glyphs .*\"hamnix-base\"'          "package hamnix-base listed"
assert_grep 'glyphs .*\"hambrowse\"'            "package hambrowse listed"
assert_grep 'glyphs .*\"webkitgtk\"'            "package webkitgtk listed"
assert_grep 'glyphs .*\"native web browser\"'   "short description rendered"

# --- category counts computed from `hpm list` state -------------------------
assert_grep '^CAT_ALL 6'                        "category counter: All = 6"
assert_grep '^CAT_INST 3'                       "category counter: Installed = 3"
assert_grep '^CAT_AVAIL 3'                      "category counter: Available = 3"
assert_grep '^CAT_UPGRAD 1'                     "category counter: Upgradable = 1 (hambrowse 0.8->0.9)"
assert_grep 'glyphs .*\"upgrade\"'              "upgradable badge rendered on the row"
assert_grep 'glyphs .*\"installed\"'            "installed badge rendered"
assert_grep 'glyphs .*\"available\"'            "available badge rendered"

# --- clicking a sidebar category filters the list ---------------------------
assert_grep '^CAT_HIT 6'                         "sidebar click hit-tests to a category (code 6)"
assert_grep '^CAT_SEL 1'                         "selected category = Installed"
assert_grep '^FILT_INST 3'                       "Installed category narrows list to 3"

# --- clicking a list row (offset past the sidebar) selects + fills detail ---
assert_grep '^HIT 5'                            "row click hit-tests to select"
assert_grep '^SEL 2'                            "selected package index 2 (hambrowse)"
assert_grep '^SEL_NAME hambrowse'               "selected package name is hambrowse"
assert_grep 'glyphs .*\"Version:\"'             "detail: version label"
assert_grep 'glyphs .*\"0.9\"'                  "detail: parsed version value"
assert_grep 'glyphs .*\"Depends:\"'             "detail: depends label"
assert_grep 'glyphs .*\"webkitgtk, hamnix-base\"' "detail: parsed dependency list"
assert_grep 'glyphs .*\"#hamnix-system\"'       "detail: parsed target"

if [ "$fail" -ne 0 ]; then echo "[hamsoftware-host] OVERALL FAIL"; exit 1; fi
echo "[hamsoftware-host] OVERALL PASS"
