#!/usr/bin/env bash
# scripts/test_hamnotes_host.sh — FAST, QEMU-free host gate for the Notes app
# (lib/hamnotescore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). It renders the empty pad (New/Save toolbar visible),
# types a scripted note, fires SAVE (Ctrl-S) which writes note-0.txt to a real
# scratch dir, fires NEW (Ctrl-N) which blanks the editor onto note-1, then
# pages back (Prev) which RELOADS note-0 off disk — proving a saved note
# persists. Four PNGs a human/agent can LOOK at are produced, the buffer
# lengths + ON-DISK byte counts are asserted, AND the NATIVE Hamnix build is
# confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamnotes_host"
ROOT="$OUT/notes_scratch"
mkdir -p "$OUT"
rm -rf "$ROOT"
mkdir -p "$ROOT"
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
if ! "$BIN" "$ROOT" "$OUT/notes_before.ppm" "$OUT/notes_after.ppm" \
        "$OUT/notes_new.ppm" "$OUT/notes_reload.ppm" >"$DUMP" 2>&1; then
    echo "[notes-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after new reload; do
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

# --- scene / toolbar renders ------------------------------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 360 280 #eceef2'         "notes window background"
assert_grep '^glyphs 10 6 \"Notes\"'            "title label"
assert_grep 'glyphs .*\"New\"'                  "New toolbar button rendered"
assert_grep 'glyphs .*\"Save\"'                 "Save toolbar button rendered"
assert_grep 'glyphs .*\"Note 1/2\"'             "note indicator rendered (paged back to note 1 of 2)"
assert_grep '^PIX 20 120 #fffef0'               "raster paper pixel = pale note"

# --- typing -----------------------------------------------------------------
assert_grep '^LEN0 0'                           "buffer starts empty"
# Default script types "Buy milk\nCall Sam" then one backspace -> 16 chars.
assert_grep '^LEN1 16'                          "typed text + backspace edit gives 16 chars"
assert_grep '^DIRTY 1'                          "buffer marked dirty after edits"
assert_grep 'glyphs .*\"Buy milk\"'             "first line rendered"
assert_grep 'glyphs .*\"Call Sa\"'             "second line rendered (backspaced)"

# --- SAVE persists to a real file ------------------------------------------
assert_grep '^DIRTY_AFTER_SAVE 0'              "Ctrl-S clears the dirty flag"
assert_grep '^FILE0_LEN 16'                     "Ctrl-S wrote 16 bytes to note-0.txt on disk"

# --- NEW blanks the editor onto a fresh note --------------------------------
assert_grep '^LEN_AFTER_NEW 0'                  "Ctrl-N clears the editor"
assert_grep '^IDX_AFTER_NEW 1'                  "Ctrl-N advances to a new note index"

# --- paging back RELOADS the saved note off disk ----------------------------
assert_grep '^IDX_AFTER_PREV 0'                 "Prev returns to note-0"
assert_grep '^LEN_AFTER_RELOAD 16'              "note-0 reloaded from disk (16 bytes)"

# --- the scratch dir really holds the note + state files --------------------
if [ -s "$ROOT/note-0.txt" ]; then echo "[notes-host] PASS note-0.txt exists on disk";
else echo "[notes-host] FAIL note-0.txt not written to $ROOT"; fail=1; fi
if [ -s "$ROOT/.state" ]; then echo "[notes-host] PASS .state index written";
else echo "[notes-host] FAIL .state index not written"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[notes-host] OVERALL FAIL"; exit 1; fi
echo "[notes-host] OVERALL PASS"
