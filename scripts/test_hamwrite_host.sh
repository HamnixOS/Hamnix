#!/usr/bin/env bash
# scripts/test_hamwrite_host.sh — FAST, QEMU-free host gate for HamWrite, the
# office word processor (lib/hamwritecore.ad drawn through lib/hamscene.ad +
# rasterized by lib/hamui_host.ad). It renders the empty page (HamWrite title
# bar + B/I/H1/Open/Save toolbar visible), types a document, double-clicks the
# first word and applies BOLD, renders the formatted page, SAVES it (Ctrl-S ->
# a HAMWRITE1 container written to a real scratch file), CLEARS the buffer, then
# RE-OPENS the file off disk (Ctrl-O) — proving the text AND the bold formatting
# survive a save->load round-trip. Two PNGs a human/agent can LOOK at are
# produced, the buffer lengths + on-disk bytes + bold-char counts are asserted,
# the FORMATTED scene is checked for a real bold-glyph op, AND the NATIVE Hamnix
# build is confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamwrite_host"
DOC="$OUT/hamwrite_scratch.hdoc"
mkdir -p "$OUT"
rm -f "$DOC"
fail=0

echo "[hamwrite-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamwrite_host.ad -o "$BIN" 2>"$OUT/hw_compile.log"; then
    echo "[hamwrite-host] FAIL: host harness did not compile"; cat "$OUT/hw_compile.log"; exit 1
fi
echo "[hamwrite-host] PASS host harness compiled -> $BIN"

echo "[hamwrite-host] compiling NATIVE hamwrite for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamwrite.ad -o "$OUT/hamwrite_native.elf" 2>"$OUT/hw_native.log"; then
    echo "[hamwrite-host] FAIL: native hamwrite did not compile"; cat "$OUT/hw_native.log"; exit 1
fi
echo "[hamwrite-host] PASS native hamwrite still compiles"

DUMP="$OUT/hw_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hw_before.ppm" "$OUT/hw_after.ppm" \
        'Hello world from HamWrite' >"$DUMP" 2>&1; then
    echo "[hamwrite-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hw_$f.ppm" "$OUT/hw_$f.png" 2>"$OUT/hw_png.log"; then
        echo "[hamwrite-host] PASS rendered $OUT/hw_$f.png"
    else
        echo "[hamwrite-host] FAIL png conversion ($f)"; cat "$OUT/hw_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamwrite-host] PASS $2";
    else echo "[hamwrite-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- window chrome / toolbar / page renders --------------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 560 384 #dfe3e8'         "hamwrite window background"
assert_grep '^fill 0 0 560 22 #3f6fb5'          "blue title bar"
assert_grep 'glyphs .*\"HamWrite\"'             "app title label"
assert_grep 'glyphs .*\"report.hdoc\"'          "filename shown in the title bar"
assert_grep 'glyphs .*\"B\"'                    "Bold toolbar button rendered"
assert_grep 'glyphs .*\"I\"'                    "Italic toolbar button rendered"
assert_grep 'glyphs .*\"H1\"'                   "Heading toolbar button rendered"
assert_grep 'glyphs .*\"Open\"'                 "Open toolbar button rendered"
assert_grep 'glyphs .*\"Save\"'                 "Save toolbar button rendered"
assert_grep '^fill 12 60 536 304 #ffffff'       "white document page rendered"
assert_grep '^PIX 4 4 #3f6fb5'                  "raster title-bar pixel = blue"
assert_grep '^PIX 200 200 #ffffff'              "raster page pixel = white paper"

# --- typing + live word/char count -----------------------------------------
assert_grep '^LEN0 0'                           "document starts empty"
assert_grep '^LEN1 25'                          "typed body is 25 chars"
assert_grep '^WORDS 4'                          "word count = 4"
assert_grep '^DIRTY 1'                          "buffer marked dirty after typing"
assert_grep 'glyphs .*\"4 words  25 chars\"'    "status-bar word/char count rendered"

# --- select the first word + apply BOLD ------------------------------------
assert_grep '^WORDSEL 5'                        "double-click selects the word (\"Hello\", 5 chars)"
assert_grep '^BOLD_HIT 3'                        "clicking the Bold button hit-tests (redraw)"
assert_grep '^BOLD1 5'                          "5 chars are now bold"
# The FORMATTED scene must contain a REAL bold-glyph op (trailing 'b' flag) for
# the bolded word, distinct from the plain remainder run.
assert_grep 'glyphs 20 66 \"Hello\" #[0-9a-f]+ b' "bolded \"Hello\" drawn as a double-struck run"
assert_grep 'glyphs [0-9]+ 66 \" world from HamWrite\" #[0-9a-f]+$' "plain remainder drawn as a normal run"

# --- SAVE writes a HAMWRITE1 container to disk ------------------------------
assert_grep '^DIRTY_AFTER_SAVE 0'              "Ctrl-S clears the dirty flag"
# File = "HAMWRITE1\n"(10) + "25\n"(3) + 25 text + 25 attr = 63 bytes.
assert_grep '^FILE_LEN 63'                      "Ctrl-S wrote the 63-byte document container"

# --- CLEAR + RE-OPEN off disk: round-trip proof ----------------------------
assert_grep '^LEN_AFTER_CLEAR 0'               "buffer cleared before reopen"
assert_grep '^LEN_AFTER_OPEN 25'               "Ctrl-O reloaded the 25-char body off disk"
assert_grep '^BOLD_AFTER_OPEN 5'               "the bold span SURVIVED the save->load round-trip"

# --- the reloaded body text matches exactly --------------------------------
if awk '/^BODY-BEGIN$/{f=1;next} /^BODY-END$/{f=0} f' "$DUMP" \
        | grep -qx 'Hello world from HamWrite'; then
    echo "[hamwrite-host] PASS reloaded body text is byte-exact"
else
    echo "[hamwrite-host] FAIL reloaded body text mismatch"; fail=1
fi

# --- the document file really exists on disk -------------------------------
if [ -s "$DOC" ]; then echo "[hamwrite-host] PASS $DOC written on disk";
else echo "[hamwrite-host] FAIL document not written to $DOC"; fail=1; fi
# and its first bytes are the self-describing magic.
if head -c 9 "$DOC" | grep -qx 'HAMWRITE1'; then
    echo "[hamwrite-host] PASS document carries the HAMWRITE1 magic";
else echo "[hamwrite-host] FAIL document missing HAMWRITE1 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hamwrite-host] OVERALL FAIL"; exit 1; fi
echo "[hamwrite-host] OVERALL PASS"
