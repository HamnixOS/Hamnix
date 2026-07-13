#!/usr/bin/env bash
# scripts/test_de_appmenu_menu_host.sh — FAST, QEMU-free host gate for the
# MATE-style Applications menu (category grouping + search + recent).
#
# Compiles lib/appmenucore.ad (the shared, extern-free menu MODEL, drawn
# through lib/hamscene.ad + rasterized by lib/hamui_host.ad) for the
# x86_64-linux host target, seeds a FIXTURE app set spanning several
# freedesktop categories, renders the FULL menu + a FILTERED ("ca") menu to
# PNGs a human/agent can LOOK at, and asserts:
#   * apps are GROUPED under category HEADERS (Accessories/Graphics/Internet/
#     Office/Games/System/Settings), each app under the right header;
#   * a SEARCH box renders at the top and its filter logic narrows the visible
#     apps live (search "ca" -> only Calculator + Camera);
#   * a RECENT section lists the most-recently-launched apps at the top.
# Then confirms the NATIVE menu client (user/hamappmenu.ad) still compiles
# from the SAME shared model — all in milliseconds, no QEMU.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/appmenu_host"
mkdir -p "$OUT"
fail=0

echo "[appmenu-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/appmenuscene_host.ad -o "$BIN" 2>"$OUT/appmenu_compile.log"; then
    echo "[appmenu-host] FAIL: host harness did not compile"
    cat "$OUT/appmenu_compile.log"; exit 1
fi
echo "[appmenu-host] PASS host harness compiled -> $BIN"

DUMP="$OUT/appmenu_dump.txt"
if ! "$BIN" "$OUT/appmenu_full.ppm" "$OUT/appmenu_filtered.ppm" >"$DUMP" 2>&1; then
    echo "[appmenu-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in full filtered; do
    if python3 scripts/ppm_to_png.py "$OUT/appmenu_$f.ppm" "$OUT/appmenu_$f.png" \
            2>"$OUT/appmenu_png.log"; then
        echo "[appmenu-host] PASS rendered $OUT/appmenu_$f.png ($(file -b "$OUT/appmenu_$f.png" 2>/dev/null))"
    else
        echo "[appmenu-host] FAIL png conversion ($f)"; cat "$OUT/appmenu_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[appmenu-host] PASS $msg"
    else
        echo "[appmenu-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- scene emitted + search box renders -----------------------------------
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Search\.\.\.\"' "search box renders (placeholder) in FULL menu"

# --- FULL menu: category grouping (each app under its header) --------------
assert_grep '^ROW FULL 0 SEARCH'                   "row 0 is the SEARCH box"
assert_grep '^ROW FULL 1 HEADER-RECENT Recent'     "Recent section header present"
assert_grep '^ROW FULL 2 APP Calculator  \[Recent\]'   "Recent lists the last-launched Calculator first"
assert_grep '^ROW FULL 3 APP Web Browser  \[Recent\]'  "Recent also lists the earlier-launched Web Browser"
assert_grep '^ROW FULL 4 HEADER Accessories'       "Accessories header"
assert_grep '^ROW FULL 5 APP Calculator  \[Accessories\]'  "Calculator grouped under Accessories"
assert_grep '^ROW FULL 6 APP Text Editor  \[Accessories\]' "Text Editor grouped under Accessories"
assert_grep '^ROW FULL 7 HEADER Graphics'          "Graphics header"
assert_grep '^ROW FULL 8 APP Image Viewer  \[Graphics\]'   "Image Viewer grouped under Graphics"
assert_grep '^ROW FULL 9 APP Camera  \[Graphics\]'         "Camera grouped under Graphics"
assert_grep '^ROW FULL 1[0-9] HEADER Internet'     "Internet header"
assert_grep '^ROW FULL 1[0-9] APP Web Browser  \[Internet\]' "Web Browser grouped under Internet"
assert_grep '^ROW FULL 1[0-9] HEADER Office'       "Office header"
assert_grep '^ROW FULL 1[0-9] APP Word Processor  \[Office\]' "Word Processor grouped under Office"
assert_grep '^ROW FULL 1[0-9] HEADER Games'        "Games header"
assert_grep '^ROW FULL 1[0-9] APP 2048  \[Games\]' "2048 grouped under Games"
assert_grep '^ROW FULL 1[0-9] HEADER System'       "System header"
assert_grep '^ROW FULL 1[0-9] APP System Monitor  \[System\]' "System Monitor grouped under System"
assert_grep '^ROW FULL 19 HEADER Settings'         "Settings header"
assert_grep '^ROW FULL 20 APP Control Center  \[Settings\]' "Control Center grouped under Settings"

# The MODEL summary reflects 10 apps + 2 recent.
assert_grep '^MODEL FULL rows=21 apps=10 recent=2' "FULL model: 21 rows, 10 apps, 2 recent"

# --- FILTERED menu: typing "ca" live-narrows to Calculator + Camera -------
assert_grep '^MODEL FILTERED rows=5 apps=10 recent=2' "FILTERED collapses to 5 rows"
assert_grep '^ROW FILTERED 0 SEARCH'               "filtered: search box still row 0"
assert_grep '^ROW FILTERED 1 HEADER Accessories'   "filtered: Accessories header kept (has a match)"
assert_grep '^ROW FILTERED 2 APP Calculator  \[Accessories\]' "filtered: Calculator matches 'ca'"
assert_grep '^ROW FILTERED 3 HEADER Graphics'      "filtered: Graphics header kept (has a match)"
assert_grep '^ROW FILTERED 4 APP Camera  \[Graphics\]' "filtered: Camera matches 'ca'"
# The non-matching sections must be GONE (no Recent, no Internet, etc.).
if grep -Eq '^ROW FILTERED [0-9]+ (HEADER Internet|HEADER Office|HEADER Games|HEADER-RECENT|APP Web Browser)' "$DUMP"; then
    echo "[appmenu-host] FAIL filter leaked non-matching sections"; fail=1
else
    echo "[appmenu-host] PASS filter dropped every non-matching section"
fi
assert_grep 'glyphs [0-9]+ [0-9]+ \"ca\"'          "filtered menu draws the live search text 'ca'"

# --- hit-test + row-kind sanity -------------------------------------------
assert_grep '^HIT search 0'                        "hit-test: pointer on the search box -> row 0"
assert_grep '^HIT miss -1'                         "hit-test: pointer left of the box misses"
assert_grep '^KIND row2 2'                         "row 2 is an APP row (launchable)"

# --- NATIVE menu client still compiles from the shared model --------------
echo "[appmenu-host] compiling NATIVE hamappmenu for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamappmenu.ad -o "$OUT/hamappmenu_native.elf" 2>"$OUT/appmenu_native.log"; then
    echo "[appmenu-host] FAIL: native hamappmenu did not compile"
    tail -40 "$OUT/appmenu_native.log"; fail=1
else
    echo "[appmenu-host] PASS native hamappmenu still compiles"
fi

if [ "$fail" -eq 0 ]; then
    echo "[appmenu-host] RESULT: PASS"
    exit 0
else
    echo "[appmenu-host] RESULT: FAIL"
    exit 1
fi
