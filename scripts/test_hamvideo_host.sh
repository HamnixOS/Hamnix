#!/usr/bin/env bash
# scripts/test_hamvideo_host.sh — FAST, QEMU-free host gate for the hamvideo
# player: the Motion-JPEG DEMUX (lib/mjpegdemux.ad) + per-frame baseline-JPEG
# DECODE (lib/jpeg.ad) and the player UI (lib/hamvideocore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). Mirrors
# scripts/test_hamaudio_host.sh.
#
# It proves, in milliseconds and with no display hardware:
#   1. lib/mjpegdemux.ad walks the shipped royalty-free fixture
#      tests/fixtures/videos/test.hmjv and lib/jpeg.ad decodes EVERY frame; the
#      harness reports frame count / geometry / fps + a per-frame non-blank
#      verdict, all checked against a Python reference (struct + PIL) over the
#      SAME file — a real decoder-correctness signal for the whole video path.
#   2. the pure player core lays out + builds the scene, which rasterizes to two
#      PNGs a human/agent can LOOK at: before = frame 0 paused, after = a mid-
#      clip frame playing (the DECODED frame is blitted into the video rect via
#      the same #128 named-image path the native compositor uses).
#   3. the pure input handlers enqueue the right commands (space -> play/pause,
#      scrub-bar click -> seek to ~mid frame).
#   4. the NATIVE user/hamvideoscene.ad still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamvideo_host"
VID="tests/fixtures/videos/test.hmjv"
mkdir -p "$OUT"
fail=0

# Ensure the fixture exists (regenerate deterministically if missing).
if [ ! -s "$VID" ]; then
    echo "[hamvideo-host] regenerating $VID"
    python3 scripts/gen_test_video.py "$VID" || { echo "[hamvideo-host] FAIL gen video"; exit 1; }
fi

echo "[hamvideo-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamvideoscene_host.ad -o "$BIN" 2>"$OUT/hamvideo_compile.log"; then
    echo "[hamvideo-host] FAIL: host harness did not compile"; cat "$OUT/hamvideo_compile.log"; exit 1
fi
echo "[hamvideo-host] PASS host harness compiled -> $BIN"

echo "[hamvideo-host] compiling NATIVE hamvideoscene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamvideoscene.ad -o "$OUT/hamvideo_native.elf" 2>"$OUT/hamvideo_native.log"; then
    echo "[hamvideo-host] FAIL: native hamvideoscene did not compile"; cat "$OUT/hamvideo_native.log"; exit 1
fi
echo "[hamvideo-host] PASS native hamvideoscene still compiles"

echo "[hamvideo-host] running host harness on $VID ..."
DUMP="$OUT/hamvideo_dump.txt"
BEFORE="$OUT/hamvideo_before.ppm"
AFTER="$OUT/hamvideo_after.ppm"
if ! "$BIN" "$VID" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hamvideo-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing).
for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamvideo_$f.ppm" "$OUT/hamvideo_$f.png" 2>"$OUT/hamvideo_png.log"; then
        echo "[hamvideo-host] PASS rendered $OUT/hamvideo_$f.png ($(file -b "$OUT/hamvideo_$f.png" 2>/dev/null))"
    else
        echo "[hamvideo-host] FAIL png conversion ($f)"; cat "$OUT/hamvideo_png.log"; fail=1
    fi
done

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }

# --- GROUND TRUTH: Python reference over the SAME file (struct + PIL) ------
REF=$(python3 - "$VID" <<'PY'
import sys, struct, io
from PIL import Image
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'HMJV', "bad magic"
ver, fl, w, h, fps, fc, res = struct.unpack('<HHHHHHI', d[4:20])
off = 20
nonblank = 0
for i in range(fc):
    ln = struct.unpack('<I', d[off:off+4])[0]; off += 4
    jpg = d[off:off+ln]; off += ln
    im = Image.open(io.BytesIO(jpg)).convert('RGB')
    lo, hi = im.getextrema()[0]           # red-channel min/max
    if hi > lo:
        nonblank += 1
print(w, h, fps, fc, nonblank)
PY
)
read -r R_W R_H R_FPS R_FC R_NB <<<"$REF"
echo "[hamvideo-host] python reference: ${R_W}x${R_H} fps=$R_FPS frames=$R_FC nonblank=$R_NB"

if [ "$(field DEMUX_OK)" = "1" ]; then
    echo "[hamvideo-host] PASS lib/mjpegdemux parsed the HMJV container"
else
    echo "[hamvideo-host] FAIL lib/mjpegdemux did not parse the container"; fail=1
fi

cmp_field() {  # cmp_field <DUMP-field> <ref-value> <label>
    local got ref; got=$(field "$1"); ref="$2"
    if [ "$got" = "$ref" ]; then
        echo "[hamvideo-host] PASS $3: $got == reference"
    else
        echo "[hamvideo-host] FAIL $3: harness=$got reference=$ref"; fail=1
    fi
}
cmp_field WIDTH          "$R_W"   "frame width"
cmp_field HEIGHT         "$R_H"   "frame height"
cmp_field FPS            "$R_FPS" "frame rate"
cmp_field NFRAMES        "$R_FC"  "frame count"
cmp_field NONBLANK_TOTAL "$R_NB"  "non-blank decoded frames"

# Every frame must be non-blank AND every frame must decode.
if [ "$(field NONBLANK_TOTAL)" = "$(field NFRAMES)" ] && [ -n "$(field NFRAMES)" ]; then
    echo "[hamvideo-host] PASS all $(field NFRAMES) frames decoded non-blank"
else
    echo "[hamvideo-host] FAIL not all frames decoded non-blank"; fail=1
fi
if grep -q "DECODE_FAIL" "$DUMP"; then
    echo "[hamvideo-host] FAIL a frame failed to decode"; grep DECODE_FAIL "$DUMP"; fail=1
fi

# --- INPUT command queue --------------------------------------------------
[ "$(field CMD_SPACE)" = "1" ] && echo "[hamvideo-host] PASS space toggles play/pause" || { echo "[hamvideo-host] FAIL space did not enqueue play/pause"; fail=1; }
[ "$(field CMD_SEEK)"  = "3" ] && echo "[hamvideo-host] PASS scrub-bar click enqueues a SEEK" || { echo "[hamvideo-host] FAIL bar click did not enqueue a seek"; fail=1; }
SEEK=$(field SEEK_FRAME)
if [ -n "$SEEK" ] && awk -v s="$SEEK" -v n="$R_FC" 'BEGIN{exit !(s>n*0.4 && s<n*0.6)}'; then
    echo "[hamvideo-host] PASS centre-bar seek landed mid-clip: frame ${SEEK} (~50% of ${R_FC})"
else
    echo "[hamvideo-host] FAIL centre-bar seek off target: frame ${SEEK} of ${R_FC}"; fail=1
fi

# --- SCENE display-list assertions ---------------------------------------
assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamvideo-host] PASS $2";
    else echo "[hamvideo-host] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_grep '^# scene v1 hamui'                "scene header emitted"
assert_grep '^glyphs 12 8 \"Video Player\"'    "bold title in the header"
assert_grep '^image .* frame'                  "decoded video frame referenced (image verb)"
assert_grep '^glyphs .* \"test.hmjv\"'         "now-playing filename shown"
assert_grep '^roundrect .* 6 #'                "rounded transport buttons drawn"

# --- RASTER proof: the decoded frame actually reached the framebuffer ------
# The video rect is a black letterbox until the decoded "frame" image is
# blitted over it. If EVERY sampled VIDPIX is pure black (0), no frame landed.
# Real decoded content is varied + non-black, so require >=2 distinct values
# and at least one non-black pixel across the sampled grid.
VIDVALS=$(grep -E '^VIDPIX ' "$DUMP" | awk '{print $4}')
NVID=$(echo "$VIDVALS" | grep -c .)
NDISTINCT=$(echo "$VIDVALS" | sort -u | grep -c .)
NNONBLACK=$(echo "$VIDVALS" | awk '$1!=0' | grep -c .)
if [ "$NVID" -ge 20 ] && [ "$NDISTINCT" -ge 2 ] && [ "$NNONBLACK" -ge 1 ]; then
    echo "[hamvideo-host] PASS decoded frame rasterized into the video rect ($NDISTINCT distinct / $NNONBLACK non-black of $NVID samples)"
else
    echo "[hamvideo-host] FAIL video rect looks blank ($NDISTINCT distinct / $NNONBLACK non-black of $NVID samples)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hamvideo-host] RESULT: PASS"
    exit 0
else
    echo "[hamvideo-host] RESULT: FAIL"
    exit 1
fi
