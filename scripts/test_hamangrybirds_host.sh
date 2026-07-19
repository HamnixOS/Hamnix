#!/usr/bin/env bash
# scripts/test_hamangrybirds_host.sh — FAST, QEMU-free host gate for the
# Angry-Birds-style slingshot physics game (lib/hamangrycore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). Mirrors
# scripts/test_hamsnake_host.sh: it compiles the app's core for the x86_64-linux
# host target, renders the scene to PNGs a human/agent can LOOK at, drives
# SCRIPTED physics (set aim, launch, step), and asserts the game evolved — the
# bird ARCS (rises above the launch line then falls back near the ground), a PIG
# target CLEARS on impact + scores, aim/power controls clamp, clearing the last
# pig is a WIN that advances the level, and exhausting the birds is a LOSE — AND
# confirms the NATIVE Hamnix build still compiles from the same core, all in
# milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamangrybirds_host"
mkdir -p "$OUT"
fail=0

echo "[angry-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamangrybirds_host.ad -o "$BIN" 2>"$OUT/angry_compile.log"; then
    echo "[angry-host] FAIL: host harness did not compile"; cat "$OUT/angry_compile.log"; exit 1
fi
echo "[angry-host] PASS host harness compiled -> $BIN"

echo "[angry-host] compiling NATIVE hamangrybirds for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamangrybirds.ad -o "$OUT/hamangry_native.elf" 2>"$OUT/angry_native.log"; then
    echo "[angry-host] FAIL: native hamangrybirds did not compile"; cat "$OUT/angry_native.log"; exit 1
fi
echo "[angry-host] PASS native hamangrybirds still compiles (device dual-target intact)"

echo "[angry-host] running host harness ..."
DUMP="$OUT/angry_dump.txt"
BEFORE="$OUT/angry_before.ppm"
AFTER="$OUT/angry_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[angry-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/angry_$f.ppm" "$OUT/angry_$f.png" 2>"$OUT/angry_png.log"; then
        echo "[angry-host] PASS rendered $OUT/angry_$f.png ($(file -b "$OUT/angry_$f.png" 2>/dev/null))"
    else
        echo "[angry-host] FAIL png conversion ($f)"; cat "$OUT/angry_png.log"; fail=1
    fi
done

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[angry-host] PASS $msg"
    else
        echo "[angry-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep '^fill 0 0 480 300 #7ec0ee'            "sky backdrop drawn"
assert_grep '^fill 0 300 480 60 #5a8f3c'           "ground strip drawn"
assert_grep '^glyphs 8 12 \"Ham Angry Birds\"'     "bold title in the HUD"
assert_grep '^fill 380 180 34 30 #74c14a'          "pig target (green) on the tower"
assert_grep '^fill 380 270 34 30 #b5793f'          "wood block (brown) at the tower base"
assert_grep '^roundrect 61 241 18 18 9 #e53935'    "red bird parked at the slingshot"
assert_grep '^glyphs 410 331 \"Launch\"'           "Launch control button label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([3-9][0-9]|[1-9][0-9][0-9])'  "rasterizer drew the scene primitives"
assert_grep '^PIX 4 4 #7ec0ee'                     "raster sky pixel = light blue"
assert_grep '^PIX 240 330 #5a8f3c'                 "raster ground pixel = green"

# --- Initial state -------------------------------------------------------
assert_grep '^STATE0 0'                            "starts in the AIM state"
assert_grep '^SCORE0 0'                            "initial score is 0"
assert_grep '^BIRDS0 4'                            "starts with the full bird count"
assert_grep '^BLOCKS0 4'                           "level 0 has its 4 blocks"
assert_grep '^PIGS0 1'                             "level 0 has one pig target"

# --- Control clamps ------------------------------------------------------
assert_grep '^ANGLE_MAX 80'                        "angle clamps at its max (80)"
assert_grep '^POWER_MAX 5'                         "power clamps at its max (5)"
assert_grep '^ANGLE_MIN 10'                        "angle clamps at its min (10)"
assert_grep '^POWER_MIN 0'                         "power clamps at its min (0)"
assert_grep '^BTN_LAUNCH 5'                        "control-row hit-test finds the Launch button"

# --- ARC: gravity makes a lobbed shot rise then fall ---------------------
# The bird must climb well above the launch height (smaller y == higher) and
# then descend back toward the ground.
STARTY=$(kv ARC_STARTY); MINY=$(kv ARC_MINY); ENDCY=$(kv ARC_ENDCY)
: "${STARTY:=0}"; : "${MINY:=99999}"; : "${ENDCY:=0}"
if [ "$MINY" -lt $((STARTY - 40)) ]; then
    echo "[angry-host] PASS shot arced UP above the launch line (startY=$STARTY minY=$MINY)"
else
    echo "[angry-host] FAIL shot did not rise (startY=$STARTY minY=$MINY)"; fail=1
fi
if [ "$ENDCY" -gt "$MINY" ]; then
    echo "[angry-host] PASS gravity pulled the shot back DOWN (minY=$MINY endY=$ENDCY)"
else
    echo "[angry-host] FAIL shot never descended (minY=$MINY endY=$ENDCY)"; fail=1
fi

# --- HIT: a bird into the pig wall clears it + scores + wins --------------
assert_grep '^HIT_PIGS_BEFORE 1'                   "one pig standing before impact"
assert_grep '^HIT_PIGS_AFTER 0'                    "the pig was cleared on impact"
assert_grep '^HIT_SCORE_DELTA 200'                 "clearing the pig scored 200"
assert_grep '^HIT_STATE 2'                         "clearing the last pig is a WIN"

# --- NEXT LEVEL: New on a win advances --------------------------------------
assert_grep '^NEXT_LEVEL 1'                        "New on a win advanced to level 2 (idx 1)"
assert_grep '^NEXT_STATE 0'                        "the new level starts back in AIM"
assert_grep '^NEXT_PIGS 2'                         "level 2 presents two pig targets"

# --- LOSE: exhausting the birds without clearing the pigs ----------------
assert_grep '^LOSE_STATE 3'                        "running out of birds is a LOSE"
assert_grep '^LOSE_BIRDS 0'                        "the LOSE happens at zero birds left"
assert_grep '^LOSE_PIGS 1'                         "the pig still stood when the birds ran out"

# --- Non-blank PNG (a healthy count of non-sky pixels) -------------------
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
sky=(0x7e,0xc0,0xee); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-sky[0])>14 or abs(px[k+1]-sky[1])>14 or abs(px[k+2]-sky[2])>14: n+=1
print("NON-SKY-PIXELS",n)
sys.exit(0 if n>=2000 else 1)
PY
then
    echo "[angry-host] PASS frame is non-blank (ground + tower + bird + HUD pixels present)"
else
    echo "[angry-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[angry-host] RESULT: PASS"
    exit 0
else
    echo "[angry-host] RESULT: FAIL"
    exit 1
fi
