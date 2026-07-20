#!/usr/bin/env bash
# scripts/test_hamslides_host.sh — FAST, QEMU-free host gate for HamSlides, the
# office PRESENTATION app (lib/hamslidescore.ad drawn through lib/hamscene.ad +
# rasterized by lib/hamui_host.ad). It builds a two-slide DECK by TYPING a title
# + bullets through the key path, adds a slide (Ctrl-N), asserts the deck model,
# renders the EDIT view (thumbnail rail + large current slide), SAVES it
# (Ctrl-S -> a HAMSLIDES1 container on a real scratch file), CLEARS the deck,
# then RE-OPENS the file off disk (Ctrl-O) — proving titles AND bullets survive a
# save->load round-trip. It then toggles PRESENT view and renders that too. Two
# PNGs a human/agent can LOOK at are produced (EDIT + PRESENT), and the NATIVE
# Hamnix build is confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamslides_host"
DOC="$OUT/hamslides_scratch.hamslides"
mkdir -p "$OUT"
rm -f "$DOC"
fail=0

echo "[hamslides-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamslides_host.ad -o "$BIN" 2>"$OUT/hsl_compile.log"; then
    echo "[hamslides-host] FAIL: host harness did not compile"; cat "$OUT/hsl_compile.log"; exit 1
fi
echo "[hamslides-host] PASS host harness compiled -> $BIN"

echo "[hamslides-host] compiling NATIVE hamslides for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamslides.ad -o "$OUT/hamslides_native.elf" 2>"$OUT/hsl_native.log"; then
    echo "[hamslides-host] FAIL: native hamslides did not compile"; cat "$OUT/hsl_native.log"; exit 1
fi
echo "[hamslides-host] PASS native hamslides still compiles"

DUMP="$OUT/hsl_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hsl_edit.ppm" "$OUT/hsl_present.ppm" >"$DUMP" 2>&1; then
    echo "[hamslides-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in edit present; do
    if python3 scripts/ppm_to_png.py "$OUT/hsl_$f.ppm" "$OUT/hsl_$f.png" 2>"$OUT/hsl_png.log"; then
        echo "[hamslides-host] PASS rendered $OUT/hsl_$f.png"
    else
        echo "[hamslides-host] FAIL png conversion ($f)"; cat "$OUT/hsl_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamslides-host] PASS $2";
    else echo "[hamslides-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- window chrome / toolbar / thumbnail rail (EDIT view) ------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 680 440 #e9ebf3'         "hamslides window background"
assert_grep '^fill 0 0 680 22 #2b2d5c'          "indigo title bar"
assert_grep 'glyphs .*"HamSlides"'              "app title label"
assert_grep 'glyphs .*"talk.hamslides"'         "filename shown in the title bar"
assert_grep 'glyphs .*"New"'                    "New toolbar button rendered"
assert_grep 'glyphs .*"Del"'                    "Del toolbar button rendered"
assert_grep 'glyphs .*"Present"'                "Present toolbar button rendered"
assert_grep 'glyphs .*"Open"'                   "Open toolbar button rendered"
assert_grep 'glyphs .*"Save"'                   "Save toolbar button rendered"
assert_grep 'glyphs .*"1 / 2"'                  "slide counter (1 / 2) rendered"
assert_grep 'glyphs [0-9]+ [0-9]+ "Welcome to HamSlides" #[0-9a-f]+ b' \
                                                "current slide title drawn bold in the canvas"
assert_grep 'glyphs [0-9]+ [0-9]+ "Native presentation app" #' \
                                                "bullet 1 drawn in the slide canvas"
assert_grep 'glyphs [0-9]+ [0-9]+ "Edit and present decks" #' \
                                                "bullet 2 drawn in the slide canvas"

# --- deck model ------------------------------------------------------------
assert_grep '^NSLIDES 2'                        "two slides after Ctrl-N add"
assert_grep '^CUR 1'                            "current slide is the newly-added slide 2"
assert_grep '^S0_NBUL 2'                        "slide 1 has two bullets"
assert_grep '^S1_NBUL 2'                        "slide 2 has two bullets"
assert_grep '^S0_TITLE Welcome to HamSlides'    "slide 1 title typed via the key path"
assert_grep '^S0_B0 Native presentation app'    "slide 1 bullet 1 typed via the key path"
assert_grep '^S0_B1 Edit and present decks'     "slide 1 bullet 2 typed via the key path"
assert_grep '^S1_TITLE Features'                "slide 2 title typed via the key path"
assert_grep '^CUR_AFTER_PGUP 0'                 "PageUp (CSI 5~) navigated to slide 1"
assert_grep '^EDIT_VIEW 0'                      "EDIT view active for the first render"
assert_grep '^PIX_TITLEBAR 2829660'             "title-bar pixel is the indigo theme (#2b2d5c)"

# --- SAVE writes a HAMSLIDES1 container to disk ----------------------------
assert_grep '^FILE_LEN 1[0-9][0-9]'             "Ctrl-S wrote the document container (>=100 bytes)"

# --- CLEAR + RE-OPEN off disk: round-trip proof ----------------------------
assert_grep '^NSLIDES_AFTER_CLEAR 1'            "deck cleared to a single slide before reopen"
assert_grep '^NSLIDES_AFTER_OPEN 2'            "Ctrl-O reloaded both slides off disk"
assert_grep '^S0_TITLE_RELOAD Welcome to HamSlides' "slide 1 title survived the round-trip"
assert_grep '^S0_B0_RELOAD Native presentation app' "slide 1 bullet survived the round-trip"
assert_grep '^S1_TITLE_RELOAD Features'         "slide 2 title survived the round-trip"
assert_grep '^S1_NBUL_RELOAD 2'                 "slide 2 bullet count survived the round-trip"

# --- PRESENT view ----------------------------------------------------------
assert_grep '^PRESENT_VIEW 1'                   "toggled into PRESENT view"
assert_grep '^PRESENT_PIX 4477880'              "PRESENT accent title band pixel is the accent (#4453b8)"
assert_grep '^PRESENT_CUR_AFTER_SPACE 1'        "Space advanced the presentation to slide 2"
assert_grep '^VIEW_AFTER_ESC 0'                 "Esc exited PRESENT back to EDIT"

# --- the document file really exists on disk with the magic ----------------
if [ -s "$DOC" ]; then echo "[hamslides-host] PASS $DOC written on disk";
else echo "[hamslides-host] FAIL document not written to $DOC"; fail=1; fi
if head -c 10 "$DOC" | grep -qx 'HAMSLIDES1'; then
    echo "[hamslides-host] PASS document carries the HAMSLIDES1 magic";
else echo "[hamslides-host] FAIL document missing HAMSLIDES1 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hamslides-host] OVERALL FAIL"; exit 1; fi
echo "[hamslides-host] OVERALL PASS"
