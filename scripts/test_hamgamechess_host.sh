#!/usr/bin/env bash
# scripts/test_hamgamechess_host.sh — FAST, QEMU-free host gate for "Chess", the
# hamGame board game layered on hamSDL (lib/hamgamechess.ad, driven through the
# PUBLIC lib/hamgame.ad Surface + font API + lib/hamgame_host.ad backend). The
# pygame-shaped board-game sibling of Snake (scripts/test_hamgamesnake_host.sh).
#
# It compiles the game's HOST harness for x86_64-linux, renders START / OPENING /
# CAPTURE board frames to PNGs a human/agent can LOOK at, drives DETERMINISTIC
# scripted move sequences (chess_move) and asserts UNFORGEABLE facts: the start
# position rasterizes 16 White + 16 Black piece-glyphs on ranks 1-2 / 7-8 (sampled
# glyph pixels, White letters near-white, Black near-black), an empty middle square
# renders neither; a legal opening (e4 e5 Nf3) moves the pawn/knight glyph to its
# new square and vacates the old; a capture (exd5) removes the captured Black pawn
# (piece count 16 -> 15) and lands a White glyph on the target square; an illegal
# move (Nb1-b3) and a wrong-side move are REJECTED leaving the board + side-to-move
# unchanged; turn alternates. It also recompiles the NATIVE (x86_64-adder-user)
# device build so the dual-target seam can't silently rot. All in milliseconds, no
# QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamgamechess_host"
mkdir -p "$OUT"
fail=0

echo "[chess-host] compiling host harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamgamechess_host.ad -o "$BIN" 2>"$OUT/hamgamechess_compile.log"; then
    echo "[chess-host] FAIL: host harness did not compile"; cat "$OUT/hamgamechess_compile.log"; exit 1
fi
echo "[chess-host] PASS host harness compiled -> $BIN"

echo "[chess-host] compiling NATIVE hamgamechess for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamgamechess.ad -o "$OUT/hamgamechess_native.elf" 2>"$OUT/hamgamechess_native.log"; then
    echo "[chess-host] FAIL: native hamgamechess did not compile"; cat "$OUT/hamgamechess_native.log"; exit 1
fi
echo "[chess-host] PASS native hamgamechess compiles (device dual-target intact)"

echo "[chess-host] running host harness ..."
DUMP="$OUT/hamgamechess_dump.txt"
START="$OUT/hamgamechess_start.ppm"
OPENING="$OUT/hamgamechess_opening.ppm"
CAPTURE="$OUT/hamgamechess_capture.ppm"
if ! "$BIN" "$START" "$OPENING" "$CAPTURE" >"$DUMP" 2>&1; then
    echo "[chess-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in start opening capture; do
    if python3 scripts/ppm_to_png.py "$OUT/hamgamechess_$f.ppm" "$OUT/hamgamechess_$f.png" 2>"$OUT/hamgamechess_png.log"; then
        echo "[chess-host] PASS rendered $OUT/hamgamechess_$f.png ($(file -b "$OUT/hamgamechess_$f.png" 2>/dev/null))"
    else
        echo "[chess-host] FAIL png conversion ($f)"; cat "$OUT/hamgamechess_png.log"; fail=1
    fi
done

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_eq() {
    local k="$1" want="$2" msg="$3" got
    got="$(kv "$k")"
    if [ "$got" = "$want" ]; then
        echo "[chess-host] PASS $msg ($k=$got)"
    else
        echo "[chess-host] FAIL $msg ($k=$got, want $want)"; fail=1
    fi
}

assert_gt() {
    local k="$1" min="$2" msg="$3" got
    got="$(kv "$k")"
    if [ -n "$got" ] && [ "$got" -gt "$min" ]; then
        echo "[chess-host] PASS $msg ($k=$got > $min)"
    else
        echo "[chess-host] FAIL $msg ($k=$got, want > $min)"; fail=1
    fi
}

# --- START POSITION: standard board, White to move -------------------------
assert_eq TURN0    0  "game starts with White to move"
assert_eq P_E2     1  "e2 = White pawn"
assert_eq P_E7    -1  "e7 = Black pawn"
assert_eq P_E1     6  "e1 = White king"
assert_eq P_D8    -5  "d8 = Black queen"
assert_eq WCOUNT0 16  "White has 16 pieces"
assert_eq BCOUNT0 16  "Black has 16 pieces"

# --- GLYPH RASTER: 16 White + 16 Black letters on the home ranks -----------
assert_eq WGLYPHS 16  "16 White piece-glyphs rasterized on ranks 1-2"
assert_eq BGLYPHS 16  "16 Black piece-glyphs rasterized on ranks 7-8"
assert_gt E2_W     4  "e2 White pawn renders near-white glyph pixels"
assert_eq E2_B     0  "e2 has no Black glyph pixels"
assert_eq E4_W0    0  "empty e4 renders no White glyph pixels"
assert_eq E4_B0    0  "empty e4 renders no Black glyph pixels"
assert_gt E7_B     4  "e7 Black pawn renders near-black glyph pixels"
assert_eq E7_W     0  "e7 has no White glyph pixels"

# --- Non-blank START PNG (a healthy count of non-background pixels) ---------
if python3 - "$START" <<'PY'
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
bg=(0x1e,0x1e,0x26); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>16 or abs(px[k+1]-bg[1])>16 or abs(px[k+2]-bg[2])>16: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=2000 else 1)
PY
then
    echo "[chess-host] PASS start frame is non-blank (board + pieces + labels present)"
else
    echo "[chess-host] FAIL start frame looks blank"; fail=1
fi

# --- LEGAL OPENING: e4 e5 Nf3 all accepted, pieces relocate ----------------
assert_eq MV_E4       1  "e2-e4 accepted"
assert_eq MV_E5       1  "e7-e5 accepted"
assert_eq MV_NF3      1  "Ng1-f3 accepted"
assert_eq P_E2_AFTER  0  "e2 vacated after the pawn moved"
assert_eq P_E4_AFTER  1  "White pawn now on e4"
assert_eq P_E5_AFTER -1  "Black pawn now on e5"
assert_eq P_G1_AFTER  0  "g1 vacated after the knight moved"
assert_eq P_F3_AFTER  2  "White knight now on f3"
assert_eq TURN_AFTER  1  "turn alternated to Black after 3 half-moves"
# pixel evidence: glyph left e2, arrived on e4/f3
assert_eq E2_W1       0  "e2 square now bare (no White glyph)"
assert_gt E4_W1       4  "moved pawn's White glyph now on e4"
assert_gt F3_W1       4  "moved knight's White glyph now on f3"

# --- CAPTURE: exd5 removes the Black pawn -----------------------------------
assert_eq CAP_BCOUNT_PRE   16 "Black still has 16 pieces before the capture"
assert_eq CAP_D5_PRE       -1 "d5 holds a Black pawn before the capture"
assert_eq CAP_RET           1 "exd5 capture accepted"
assert_eq CAP_E4_POST       0 "e4 vacated after capturing"
assert_eq CAP_D5_POST       1 "White pawn now stands on d5"
assert_eq CAP_BCOUNT_POST  15 "captured Black pawn removed (16 -> 15)"
assert_eq CAP_WCOUNT_POST  16 "White keeps all 16 pieces"
assert_gt CAP_D5_W          4 "capturing White pawn's glyph rendered on d5"
assert_eq CAP_D5_B          0 "no Black glyph remains on d5"

# --- ILLEGAL / WRONG-SIDE moves rejected, board unchanged ------------------
assert_eq ILLEGAL_RET   0 "illegal Nb1-b3 rejected"
assert_eq ILLEGAL_SRC   2 "knight still on b1 after the rejected move"
assert_eq ILLEGAL_DST   0 "b3 still empty after the rejected move"
assert_eq ILLEGAL_TURN  0 "side-to-move unchanged after the rejected move"
assert_eq WRONGSIDE_RET 0 "Black cannot move while it is White's turn"

if [ "$fail" -eq 0 ]; then
    echo "[chess-host] RESULT: PASS"
    exit 0
else
    echo "[chess-host] RESULT: FAIL"
    exit 1
fi
