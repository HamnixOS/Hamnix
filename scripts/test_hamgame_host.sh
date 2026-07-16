#!/usr/bin/env bash
# scripts/test_hamgame_host.sh — FAST, QEMU-free host gate for hamGame, the
# pygame-shaped game library layered on hamSDL (lib/hamgame.ad + lib/hamgame_dev.ad
# + lib/hamgame_host.ad) and its demo game "Coin Dash" (lib/hamgamedemo.ad).
# Mirrors scripts/test_hamsdl_host.sh: it compiles the demo's HOST harness for
# x86_64-linux, renders game frames to PNGs a human/agent can LOOK at, drives
# SCRIPTED input (raw queue + real DE arrow wire lines through the shared parser),
# and asserts the display-Surface backbuffer rasterized (pixel colours), that
# INPUT moves the sprite, that DELTA-TIME advances the animation frame, and that
# AABB COLLISION scores — all in milliseconds, no QEMU. It also confirms the
# NATIVE (x86_64-adder-user) device build still compiles from the same library,
# so the dual-target seam can't silently rot.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamgamedemo_host"
mkdir -p "$OUT"
fail=0

echo "[hamgame-host] compiling demo host harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamgamedemo_host.ad -o "$BIN" 2>"$OUT/hamgame_compile.log"; then
    echo "[hamgame-host] FAIL: host harness did not compile"; cat "$OUT/hamgame_compile.log"; exit 1
fi
echo "[hamgame-host] PASS host harness compiled -> $BIN"

echo "[hamgame-host] compiling NATIVE hamgamedemo for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamgamedemo.ad -o "$OUT/hamgamedemo_native.elf" 2>"$OUT/hamgame_native.log"; then
    echo "[hamgame-host] FAIL: native hamgamedemo did not compile"; cat "$OUT/hamgame_native.log"; exit 1
fi
echo "[hamgame-host] PASS native hamgamedemo still compiles (device dual-target intact)"

echo "[hamgame-host] running demo host harness ..."
DUMP="$OUT/hamgame_dump.txt"
BEFORE="$OUT/hamgame_before.ppm"
AFTER="$OUT/hamgame_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hamgame-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamgame_$f.ppm" "$OUT/hamgame_$f.png" 2>"$OUT/hamgame_png.log"; then
        echo "[hamgame-host] PASS rendered $OUT/hamgame_$f.png ($(file -b "$OUT/hamgame_$f.png" 2>/dev/null))"
    else
        echo "[hamgame-host] FAIL png conversion ($f)"; cat "$OUT/hamgame_png.log"; fail=1
    fi
done

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hamgame-host] PASS $msg"
    else
        echo "[hamgame-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Rasterizer: the display Surface backbuffer was blitted + sampled ------
assert_grep '^PRIMS [1-9]'                    "rasterizer drew the frame primitives (image + HUD)"
assert_grep '^PIX_BG 2 120 #121622'           "backbuffer backdrop pixel = dark navy"
assert_grep '^PIX_PLAYER 120 208 #5ac8ff'     "player avatar body pixel = cyan (sprite+colourkey blit)"
# coin body: a warm gold/cream highlight, definitely not the dark backdrop
assert_grep '^PIX_COIN 120 38 #f'             "coin body pixel is a bright (non-backdrop) colour"

# --- Non-blank PNG (a healthy count of non-background pixels) ---------------
if python3 - "$BEFORE" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
assert d[:2]==b'P6'
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    s=i
    while i<len(d) and d[i] not in b' \t\n\r': i+=1
    vals.append(int(d[s:i]))
w,h,mx=vals; i+=1; px=d[i:]
bg=(0x12,0x16,0x22); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>10 or abs(px[k+1]-bg[1])>10 or abs(px[k+2]-bg[2])>10: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=300 else 1)
PY
then
    echo "[hamgame-host] PASS frame is non-blank (player + coin + HUD pixels present)"
else
    echo "[hamgame-host] FAIL frame looks blank"; fail=1
fi

# --- INPUT (wire parser): RIGHT arrow slid the player right ----------------
PX0=$(kv PLAYERX0); PX1=$(kv PLAYERX1)
if [ -n "$PX0" ] && [ -n "$PX1" ] && [ "$PX1" -gt "$PX0" ]; then
    echo "[hamgame-host] PASS RIGHT-arrow moved player right: $PX0 -> $PX1"
else
    echo "[hamgame-host] FAIL player did not move right on RIGHT arrow (x0=$PX0 x1=$PX1)"; fail=1
fi

# --- INPUT (wire parser): UP arrow slid the player up ----------------------
PY0=$(kv PLAYERY0); PY1=$(kv PLAYERY1)
if [ -n "$PY0" ] && [ -n "$PY1" ] && [ "$PY1" -lt "$PY0" ]; then
    echo "[hamgame-host] PASS UP-arrow moved player up: $PY0 -> $PY1"
else
    echo "[hamgame-host] FAIL player did not move up on UP arrow (y0=$PY0 y1=$PY1)"; fail=1
fi

# --- INPUT (raw queue): a LEFT keydown slid the player back left -----------
PX2=$(kv PLAYERX2)
if [ -n "$PX2" ] && [ -n "$PX1" ] && [ "$PX2" -lt "$PX1" ]; then
    echo "[hamgame-host] PASS raw-queue LEFT keydown moved player back left: $PX1 -> $PX2"
else
    echo "[hamgame-host] FAIL player did not move left on raw LEFT keydown (x1=$PX1 x2=$PX2)"; fail=1
fi

# --- TIMING: delta-time advanced the animation frame -----------------------
FB=$(kv FRAME_BEFORE); FA=$(kv FRAME_AFTER)
if [ -n "$FB" ] && [ -n "$FA" ] && [ "$FA" != "$FB" ]; then
    echo "[hamgame-host] PASS delta-time advanced the spritesheet animation frame: $FB -> $FA"
else
    echo "[hamgame-host] FAIL animation frame did not advance on delta-time (before=$FB after=$FA)"; fail=1
fi

# --- COLLISION / scoring: coin dropped on the player scored a pickup -------
assert_grep '^SCOREHIT_BEFORE 0'              "no score before the pickup"
assert_grep '^SCOREHIT_AFTER 1'               "AABB collision scored the coin pickup (gameplay works)"

if [ "$fail" -eq 0 ]; then
    echo "[hamgame-host] RESULT: PASS"
    exit 0
else
    echo "[hamgame-host] RESULT: FAIL"
    exit 1
fi
