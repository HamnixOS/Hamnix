#!/usr/bin/env bash
# scripts/test_hamnotes_host.sh — FAST, QEMU-free host gate for the Notes
# scratchpad (lib/hamnotescore.ad drawn through lib/hamscene.ad + rasterized
# by lib/hamui_host.ad). Renders the empty pad, feeds a SCRIPTED string of
# keystrokes (via the "d <code>" wire lines the compositor delivers) including
# a newline and a backspace edit, re-renders to a PNG a human/agent can LOOK
# at, asserts the buffer length + dirty flag, AND confirms the NATIVE Hamnix
# build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamnotes_host"
mkdir -p "$OUT"
fail=0

echo "[notes-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamnotesscene_host.ad -o "$BIN" 2>"$OUT/notes_compile.log"; then
    echo "[notes-host] FAIL: host harness did not compile"; cat "$OUT/notes_compile.log"; exit 1
fi
echo "[notes-host] PASS host harness compiled -> $BIN"

echo "[notes-host] compiling NATIVE hamnotesscene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamnotesscene.ad -o "$OUT/hamnotes_native.elf" 2>"$OUT/notes_native.log"; then
    echo "[notes-host] FAIL: native hamnotesscene did not compile"; cat "$OUT/notes_native.log"; exit 1
fi
echo "[notes-host] PASS native hamnotesscene still compiles"

DUMP="$OUT/notes_dump.txt"
if ! "$BIN" "$OUT/notes_before.ppm" "$OUT/notes_after.ppm" >"$DUMP" 2>&1; then
    echo "[notes-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/notes_$f.ppm" "$OUT/notes_$f.png" 2>"$OUT/notes_png.log"; then
        echo "[notes-host] PASS rendered $OUT/notes_$f.png"
    else
        echo "[notes-host] FAIL png conversion ($f)"; cat "$OUT/notes_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[notes-host] PASS $2";
    else echo "[notes-host] FAIL $2 (missing: $1)"; fail=1; fi
}

assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 360 280 #d4d0c8'         "notes window background"
assert_grep '^glyphs 10 8 \"Notes\"'            "title label"
assert_grep '^LEN0 0'                           "buffer starts empty"
# Default script types "Buy milk\nCall Sam" then one backspace -> 16 chars.
assert_grep '^LEN1 16'                          "typed text + backspace edit gives 16 chars"
assert_grep '^DIRTY 1'                          "buffer marked dirty after edits"
assert_grep '^DIRTY_AFTER_SAVE 0'              "mark_saved clears the dirty flag"
assert_grep 'glyphs .*\"Buy milk\"'             "first line rendered"
assert_grep 'glyphs .*\"Call Sa\"'             "second line rendered (backspaced)"
assert_grep '^PIX 20 60 #fffef0'               "raster paper pixel = pale note"

if [ "$fail" -ne 0 ]; then echo "[notes-host] OVERALL FAIL"; exit 1; fi
echo "[notes-host] OVERALL PASS"
