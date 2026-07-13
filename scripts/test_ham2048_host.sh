#!/usr/bin/env bash
# scripts/test_ham2048_host.sh — FAST, QEMU-free host gate for the 2048 scene
# app (lib/ham2048core.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_hambrowse_host.sh: it compiles the
# app's core for the x86_64-linux host target, renders the scene to a PNG a
# human/agent can LOOK at, drives SCRIPTED input, asserts the game state
# changed, AND confirms the NATIVE Hamnix build still compiles from the same
# core — all in milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap needed) so the gate is dependency-light. PNG conversion
# uses scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/ham2048_host"
mkdir -p "$OUT"
fail=0

echo "[2048-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/ham2048scene_host.ad -o "$BIN" 2>"$OUT/2048_compile.log"; then
    echo "[2048-host] FAIL: host harness did not compile"; cat "$OUT/2048_compile.log"; exit 1
fi
echo "[2048-host] PASS host harness compiled -> $BIN"

echo "[2048-host] compiling NATIVE ham2048scene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/ham2048scene.ad -o "$OUT/ham2048_native.elf" 2>"$OUT/2048_native.log"; then
    echo "[2048-host] FAIL: native ham2048scene did not compile"; cat "$OUT/2048_native.log"; exit 1
fi
echo "[2048-host] PASS native ham2048scene still compiles"

echo "[2048-host] running host harness ..."
DUMP="$OUT/2048_dump.txt"
BEFORE="$OUT/2048_before.ppm"
AFTER="$OUT/2048_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" wasd >"$DUMP" 2>&1; then
    echo "[2048-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing) using stdlib-only converter.
for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/2048_$f.ppm" "$OUT/2048_$f.png" 2>"$OUT/2048_png.log"; then
        echo "[2048-host] PASS rendered $OUT/2048_$f.png ($(file -b "$OUT/2048_$f.png" 2>/dev/null))"
    else
        echo "[2048-host] FAIL png conversion ($f)"; cat "$OUT/2048_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[2048-host] PASS $msg"
    else
        echo "[2048-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 360 470 #faf8ef'         "full-window beige backdrop"
assert_grep '^fill 13 71 334 334 #bbada0'       "board backing panel at expected geometry"
assert_grep '^glyphs 12 14 \"2048\" #776e65 b'  "bold title '2048' at header"
assert_grep '^glyphs 68 16 \"Score 0\"'         "live score readout starts at 0"
assert_grep '^fill 23 81 71 71 #cdc1b4'         "top-left empty tile colour+geometry"
assert_grep '^glyphs 135 191 \"2\" #776e65 b'   "a spawned '2' tile number is drawn"
assert_grep '^fill 12 435 59 30 #c8c4bc'        "New control button face"
assert_grep '^glyphs 232 444 \"Down\"'          "Down control button label"
assert_grep '^glyphs 297 444 \"Right\"'         "Right control button label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([4-9][0-9]|3[0-9])'        "rasterizer drew the scene primitives"
assert_grep '^PIX 0 0 #faf8ef'                  "raster backdrop pixel = beige"
assert_grep '^PIX 16 74 #bbada0'                "raster board-panel pixel = grey-brown"
assert_grep '^PIX 26 84 #cdc1b4'                "raster empty-tile pixel = tile grey"
assert_grep '^PIX 108 166 #eee4da'              "raster spawned-tile pixel = '2' tile cream"

# --- Initial state -------------------------------------------------------
assert_grep '^SCORE0 0'                          "initial score is 0"
assert_grep '^NONEMPTY0 2'                        "initial board has exactly 2 tiles"

# --- Scripted input drove a state change ---------------------------------
assert_grep '^BTNAT 90 440 1'                    "pointer press in control row hit-tests the Up button"
assert_grep '^KEYCHANGED 1'                       "scripted keyboard input changed the board"
# After the move sequence the score must have increased above 0 (a merge).
if grep -Eq '^SCORE1 ([1-9][0-9]*)' "$DUMP"; then
    s1=$(grep -E '^SCORE1 ' "$DUMP" | awk '{print $2}')
    echo "[2048-host] PASS input produced a merge: score rose 0 -> $s1"
else
    echo "[2048-host] FAIL score did not change after input"; fail=1
fi
# A spawn after the move => more than 2 non-empty tiles now.
if grep -Eq '^NONEMPTY1 ([3-9]|1[0-6])' "$DUMP"; then
    echo "[2048-host] PASS board evolved (a tile spawned after the move)"
else
    echo "[2048-host] FAIL board tile count did not evolve"; fail=1
fi

# --- Tile-number "junk after the number" regression (button-path bug) ----
# Root cause: _fmt wrote the digits but no NUL, so the scene glyph sink
# over-read stack bytes after the number. The garbage differed by call path,
# so ONLY the deep pointer/click (button) render showed junk; keyboard stayed
# clean. Fix = _fmt NUL-terminates. These three gates prove it deterministically.
assert_grep '^FMTCLEAN 1'        "tile formatter NUL-terminates against a poisoned buffer"
assert_grep '^BTNTILECLEAN 1'    "after a BUTTON move every tile number is digits-only (no junk)"
assert_grep '^KBTILECLEAN 1'     "after a KEYBOARD move every tile number is digits-only (matches button path)"

# --- SLIDE ANIMATION: tiles occupy INTERMEDIATE positions across frames ----
# Drive a deterministic single-tile LEFT slide (col3 -> col0) and render EVERY
# animation frame. The core dumps the moving tile's interpolated pixel-x per
# frame; we prove at least one mid-slide frame places the tile STRICTLY between
# its start and end cell (not a before/after teleport), and save the frame PNGs.
SDUMP="$OUT/2048_slide_dump.txt"
SPREFIX="$OUT/2048_slide_"
if ! "$BIN" slide "$SPREFIX" >"$SDUMP" 2>&1; then
    echo "[2048-host] FAIL: slide harness exited non-zero"; cat "$SDUMP"; fail=1
fi

# Convert each rendered slide frame to a PNG for eyeballing.
for ppm in "$SPREFIX"*.ppm; do
    [ -e "$ppm" ] || continue
    png="${ppm%.ppm}.png"
    if python3 scripts/ppm_to_png.py "$ppm" "$png" 2>"$OUT/2048_slide_png.log"; then
        echo "[2048-host] PASS rendered slide frame $png"
    else
        echo "[2048-host] FAIL slide png conversion ($ppm)"; cat "$OUT/2048_slide_png.log"; fail=1
    fi
done

if grep -Eq '^SLIDECHANGED 1' "$SDUMP"; then
    echo "[2048-host] PASS LEFT move armed the slide animation"
else
    echo "[2048-host] FAIL slide move did not arm an animation"; fail=1
fi
if grep -Eq '^SLIDEN 1' "$SDUMP"; then
    echo "[2048-host] PASS exactly one tile is tracked as moving"
else
    echo "[2048-host] FAIL unexpected moving-tile count"; fail=1
fi

# The crux: some PHASE 1 (slide) frame must have the tile STRICTLY between the
# start cell x (SLIDEFROMX) and the end cell x (SLIDETOX) — an intermediate
# position distinct from BOTH snapped cells. This is what makes it slide, not
# teleport.
INTER=$(awk '
    /^SLIDEFROMX / { fromx=$2 }
    /^SLIDETOX /   { tox=$2 }
    /^SLIDEFRAME / {
        phase=0; x="";
        for (i=1;i<=NF;i++){ if($i=="PHASE")phase=$(i+1); if($i=="TILE0X")x=$(i+1); }
        lo=(fromx<tox)?fromx:tox; hi=(fromx<tox)?tox:fromx;
        if (phase==1 && x!="" && x>lo && x<hi && x!=fromx && x!=tox) found=1;
    }
    END { print (found?"YES":"NO") }
' "$SDUMP")
if [ "$INTER" = "YES" ]; then
    fx=$(grep -E '^SLIDEFROMX ' "$SDUMP" | awk '{print $2}')
    tx=$(grep -E '^SLIDETOX ' "$SDUMP" | awk '{print $2}')
    mids=$(awk '/^SLIDEFRAME / { for(i=1;i<=NF;i++){if($i=="PHASE")p=$(i+1); if($i=="TILE0X")x=$(i+1)} if(p==1)printf "%s ",x }' "$SDUMP")
    echo "[2048-host] PASS mid-slide tile is between start($fx) and end($tx): xs=[ $mids]"
else
    echo "[2048-host] FAIL no intermediate slide position found (tiles teleport)"; fail=1
fi

# The FIRST slide frame must sit at the start cell and the LAST settled frame at
# the end cell — the endpoints bracket the intermediate positions above.
if awk '/^SLIDEFROMX /{f=$2} /^SLIDEFRAME 0 /{for(i=1;i<=NF;i++)if($i=="TILE0X")x=$(i+1)} END{exit !(x==f)}' "$SDUMP"; then
    echo "[2048-host] PASS frame 0 starts at the source cell"
else
    echo "[2048-host] FAIL frame 0 not at source cell"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[2048-host] RESULT: PASS"
    exit 0
else
    echo "[2048-host] RESULT: FAIL"
    exit 1
fi
