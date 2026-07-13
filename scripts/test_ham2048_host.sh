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

# --- Anti-aliased DE text assertion --------------------------------------
# DE scene text now rasterizes through the scalable, supersampled TrueType
# engine (lib/font_ttf.ad + embedded DejaVu in lib/browserfonts.ad) via
# lib/hamui_host.ad, replacing the crude on/off 8x16 bitmap that turned the
# bold "2048" header into a blob. The defining property of the AA path is
# INTERMEDIATE-coverage pixels: in the header band (over the beige #faf8ef
# backdrop, ink #776e65) the pure-bitmap path could only ever emit the exact
# background or exact ink colour; anti-aliasing emits blended greys in between.
# Requiring a healthy count of such blended pixels in the title band proves the
# scalable engine is live and would catch a silent regression to the bitmap.
if python3 - "$BEFORE" <<'PY'
import sys
p=sys.argv[1]
d=open(p,'rb').read()
# parse P6 header: magic, w, h, maxval, then binary
assert d[:2]==b'P6', "not P6 ppm"
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if i<len(d) and d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    s=i
    while i<len(d) and d[i] not in b' \t\n\r': i+=1
    vals.append(int(d[s:i]))
w,h,mx=vals
i+=1  # single whitespace after maxval
px=d[i:]
def rgb(x,y):
    o=(y*w+x)*3
    return px[o],px[o+1],px[o+2]
BG=(0xfa,0xf8,0xef); INK=(0x77,0x6e,0x65)
def near(a,b,t=8): return all(abs(a[k]-b[k])<=t for k in range(3))
inter=0
# header band: title/score row lives around y=14..32, x=10..320
for y in range(12,34):
    for x in range(10,320):
        c=rgb(x,y)
        if not near(c,BG) and not near(c,INK,10):
            # blended pixel strictly between backdrop and ink
            inter+=1
print("AA-INTERMEDIATE-PIXELS", inter)
sys.exit(0 if inter>=40 else 1)
PY
then
    echo "[2048-host] PASS header text is anti-aliased (blended coverage pixels present)"
else
    echo "[2048-host] FAIL header text has no AA blended pixels (bitmap regression?)"; fail=1
fi

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

# --- BOUNDED PER-MOVE COST (the "slows down after a few turns" bug class) --
# User report on the installed image: 2048 "looks really good for a little
# while. Once you've played it for a few turns it slows way down" — the classic
# unbounded-growth performance bug, where per-move render work (scene display-
# list size / animation-list length) accumulates instead of resetting each
# frame, so every move gets more expensive.
#
# The app is BOUNDED by construction: hamscene_begin() resets the display-list
# buffer at the top of every build, the board/animation state is fixed 16-entry
# arrays reset each move, and the display list is rebuilt from scratch — so the
# per-move cost depends only on how many tiles are on the board (a constant
# ceiling), NOT on how many moves have been played. This gate PROVES that and
# guards against a future regression (any per-move append) that would reintro-
# duce the bug. `grow N` plays N real moves (move + full animation drain, reset
# on game-over) and reports the settled display-list size + moving-tile count at
# move 5 and move N, plus the maxima over the whole run.
GDUMP="$OUT/2048_grow_dump.txt"
GAFTER="$OUT/2048_after120moves.ppm"
if ! "$BIN" grow 120 "$GAFTER" >"$GDUMP" 2>&1; then
    echo "[2048-host] FAIL: grow harness exited non-zero"; cat "$GDUMP"; fail=1
fi
# Save the after-120-moves board as a PNG for eyeballing (still renders fine).
if [ -e "$GAFTER" ] && python3 scripts/ppm_to_png.py "$GAFTER" "$OUT/2048_after120moves.png" 2>"$OUT/2048_grow_png.log"; then
    echo "[2048-host] PASS rendered after-120-moves board $OUT/2048_after120moves.png"
else
    echo "[2048-host] FAIL after-120-moves png conversion"; cat "$OUT/2048_grow_png.log" 2>/dev/null; fail=1
fi
GSEG5=$(awk '/^SEG5 /{print $2}' "$GDUMP")
GSEGN=$(awk '/^SEGN /{print $2}' "$GDUMP")
GSEGMAX=$(awk '/^SEGMAX /{print $2}' "$GDUMP")
GANIMMAX=$(awk '/^ANIMMAX /{print $2}' "$GDUMP")
: "${GSEG5:=0}" "${GSEGN:=0}" "${GSEGMAX:=0}" "${GANIMMAX:=0}"

# (1) The settled display list at move 120 must be within a tight band of move 5
#     — NOT climbing. Allow a 1.5x ceiling to absorb board-fullness variation
#     (a fuller board legitimately draws a few more tile fills/glyphs); a real
#     per-move leak blows far past this within a handful of moves.
if [ "$GSEG5" -gt 0 ] && \
   awk -v a="$GSEG5" -v b="$GSEGN" 'BEGIN{exit !(b <= a*3/2 && b >= a/2)}'; then
    echo "[2048-host] PASS per-move display list is bounded: SEG@5=$GSEG5 ~ SEG@120=$GSEGN (no growth)"
else
    echo "[2048-host] FAIL per-move display list GREW with move count: SEG@5=$GSEG5 -> SEG@120=$GSEGN"; fail=1
fi
# (2) The peak display list over 120 moves must stay well under the 16384-byte
#     scene cap (past which primitives silently truncate) — proving there is
#     headroom and no slow creep toward the ceiling.
if [ "$GSEGMAX" -gt 0 ] && [ "$GSEGMAX" -lt 4000 ]; then
    echo "[2048-host] PASS peak display list bounded far below the 16384 cap: SEGMAX=$GSEGMAX"
else
    echo "[2048-host] FAIL peak display list not bounded below cap: SEGMAX=$GSEGMAX"; fail=1
fi
# (3) The moving-tile animation list never exceeds the 16-tile board (fixed
#     array; reset every move) — it does not accumulate stale entries.
if [ "$GANIMMAX" -ge 0 ] && [ "$GANIMMAX" -le 16 ]; then
    echo "[2048-host] PASS animation list bounded by the board (<=16): ANIMMAX=$GANIMMAX"
else
    echo "[2048-host] FAIL animation list exceeded the board: ANIMMAX=$GANIMMAX"; fail=1
fi

# (4) CONTROL — prove the gate above actually has teeth. `growleak 120` runs the
#     IDENTICAL move loop but deliberately APPENDS m primitives per move without
#     the begin() reset (exactly the reported bug class). Its display list MUST
#     climb steeply with move count (SEGN >> SEG5), i.e. it WOULD fail assertion
#     (1). This confirms a genuine per-move leak is detected, so the real path's
#     flatness above is meaningful and not a dead assertion.
LDUMP="$OUT/2048_growleak_dump.txt"
if ! "$BIN" growleak 120 >"$LDUMP" 2>&1; then
    echo "[2048-host] FAIL: growleak control exited non-zero"; cat "$LDUMP"; fail=1
fi
LSEG5=$(awk '/^SEG5 /{print $2}' "$LDUMP")
LSEGN=$(awk '/^SEGN /{print $2}' "$LDUMP")
: "${LSEG5:=0}" "${LSEGN:=0}"
if [ "$LSEG5" -gt 0 ] && awk -v a="$LSEG5" -v b="$LSEGN" 'BEGIN{exit !(b > a*3/2)}'; then
    echo "[2048-host] PASS control leak is detectably unbounded: SEG@5=$LSEG5 -> SEG@120=$LSEGN (gate has teeth)"
else
    echo "[2048-host] FAIL control leak did not grow — bounded-growth gate would be a dead assertion"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[2048-host] RESULT: PASS"
    exit 0
else
    echo "[2048-host] RESULT: FAIL"
    exit 1
fi
