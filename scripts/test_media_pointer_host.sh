#!/usr/bin/env bash
# scripts/test_media_pointer_host.sh — FAST, QEMU-free host gate proving the
# shipped media players' MOUSE TRANSPORT and video EOF REPLAY work at the code
# level, guarding two USER-reported regressions:
#
#   BUG 1 (pointer-field mis-parse): the kernel pointer router
#     (sys/src/9/port/devwsys.ad) emits each /event pointer line as
#     "m <x> <y> <buttons> <dz>" — a leading 'm' then FOUR ints, dz ALWAYS
#     present. The players' shared handlers (lib/hamvideocore.ad
#     hamvideo_handle_pointer_line + lib/hamaudiocore.ad
#     hamaudio_handle_pointer_line) must take the FIRST THREE ints after the 'm'
#     as x, y, buttons and IGNORE the trailing dz. The old inline app copies took
#     the LAST THREE, so a real Play click "m X Y 1 0" read buttons as dz==0 and
#     NO mouse transport (Play/Stop/seek) ever fired in either player.
#     This gate feeds a REAL "m <playX> <playY> 1 0" line at each player's own
#     Play-button coordinate and asserts the PLAYPAUSE command fires — the exact
#     input the last-three parse got wrong (last three of that line = [Y,1,0]).
#
#   BUG 2 (video no-replay after EOF): hamvideo_eof_rewind must return to a clean
#     idle at frame 0 with playback stopped, so pressing Play from EOF restarts
#     from the top (the old code settled at the LAST frame, making Play a no-op).
#
# NB: the two media cores share PUBLIC globals (BTN_W, ...) so they cannot be
# merged into one program — each player has its own harness binary.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
fail=0

run_harness() {  # run_harness <src.ad> <label>
    local src="$1" label="$2" bin="$OUT/$2"
    echo "[media-pointer] compiling $label ($src) for x86_64-linux ..."
    if ! python3 -m compiler.adder compile --target=x86_64-linux \
            "user/$src" -o "$bin" 2>"$OUT/${label}_compile.log"; then
        echo "[media-pointer] FAIL: $label did not compile"
        cat "$OUT/${label}_compile.log"; fail=1; return
    fi
    local dump="$OUT/${label}.txt"
    if ! "$bin" >"$dump" 2>&1; then
        echo "[media-pointer] FAIL: $label harness exited non-zero"
        cat "$dump"; fail=1; return
    fi
    cat "$dump"
    if ! grep -q '^RESULT PASS$' "$dump"; then
        echo "[media-pointer] FAIL: $label did not report RESULT PASS"; fail=1
    fi
}

assert_field() {  # assert_field <dumpfile> <FIELD> <expected> <desc>
    local dump="$1" field="$2" exp="$3" desc="$4"
    local got; got=$(grep -E "^$field " "$dump" | head -1 | awk '{print $2}')
    if [ "$got" = "$exp" ]; then
        echo "[media-pointer] PASS $desc ($field=$got)"
    else
        echo "[media-pointer] FAIL $desc ($field=$got, want $exp)"; fail=1
    fi
}

run_harness video_pointer_host.ad video_pointer_host
run_harness audio_pointer_host.ad audio_pointer_host

VDUMP="$OUT/video_pointer_host.txt"
ADUMP="$OUT/audio_pointer_host.txt"

# BUG 1 — a Play click via a real "m x y 1 0" line fires PLAYPAUSE (cmd 1).
assert_field "$VDUMP" VIDEO_PLAY_CMD    1 "video Play click fires PLAYPAUSE"
assert_field "$VDUMP" VIDEO_RELEASE_CMD 0 "video button release fires nothing"
assert_field "$VDUMP" VIDEO_PLAY_CMD_DZ 1 "video ignores trailing dz field"
assert_field "$ADUMP" AUDIO_PLAY_CMD    1 "audio Play click fires PLAYPAUSE"
assert_field "$ADUMP" AUDIO_RELEASE_CMD 0 "audio button release fires nothing"
assert_field "$ADUMP" AUDIO_PLAY_CMD_DZ 1 "audio ignores trailing dz field"

# BUG 2 — video EOF rewinds to frame 0, stopped (Play then restarts from top).
assert_field "$VDUMP" VIDEO_EOF_FRAME   0 "video EOF rewinds to frame 0"
assert_field "$VDUMP" VIDEO_EOF_PLAYING 0 "video EOF stops playback"

if [ "$fail" -eq 0 ]; then
    echo "[media-pointer] RESULT: PASS"
    exit 0
else
    echo "[media-pointer] RESULT: FAIL"
    exit 1
fi
