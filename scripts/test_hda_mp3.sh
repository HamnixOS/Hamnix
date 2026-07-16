#!/usr/bin/env bash
# scripts/test_hda_mp3.sh — on-device native MP3 playback through the HDA sink.
#
# Boots Hamnix once under QEMU with an `intel-hda` controller + a `hda-output`
# codec wired to QEMU's WAV audio backend, so any PCM the native HDA driver
# streams out via real stream DMA is captured to a host WAV file. The kernel
# self-test (init/main.ad boot:37.mp3, gated on /etc/mp3-test =
# ENABLE_MP3_TEST=1) reads the initramfs-staged /usr/share/sounds/test.mp3,
# decodes it in-kernel with lib/mp3decode (the SAME MPEG-1 Layer III decoder
# user/hamaudioscene.ad routes .mp3 files through), configures /dev/audioctl,
# and streams the DECODED PCM to /dev/audio (the Plan-9 cdev).
#
# This proves the WHOLE on-device .mp3 -> HDA path is REAL, not a probe:
#   * the kernel asserts the decoded format (44100 Hz, mono) and that the
#     decoded PCM is non-silent BEFORE it touches the sink — [audio-mp3] lines;
#   * the HOST parses the captured WAV and FAILS if it is all-zero / silent,
#     PASSing only when it contains real non-zero samples.
#
# Pass marker:  [test_hda_mp3] PASS
# Fail marker:  [test_hda_mp3] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hda_mp3] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_hda_mp3] (2/3) Build kernel with /etc/mp3-test marker + staged test.mp3"
INIT_ELF=build/user/init.elf ENABLE_MP3_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hda_mp3] (3/3) Boot QEMU with intel-hda -> wav backend"
set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device intel-hda \
    -device hda-output,audiodev=snd0 \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hda_mp3] --- mp3 self-test output ---"
grep -E "\[hda\]|\[audio-mp3\]|\[boot:37.mp3\]" "$LOG" || true
echo "[test_hda_mp3] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_hda_mp3] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[audio-mp3] FAIL" "$LOG"; then
    echo "[test_hda_mp3] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

# Kernel-side assertions (the driver brought the controller up, the decoder
# produced the expected non-silent PCM, and the PCM was streamed to the sink).
check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_hda_mp3] PASS: $label"
    else
        echo "[test_hda_mp3] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
check "controller init OK"          "[hda] init OK"
check "decoded format 44100/1"      "[audio-mp3] configured rate=44100 channels=1 format=s16le"
check "decoded PCM non-silent"      "[audio-mp3] decoded PCM peak"
check "PCM streamed to /dev/audio"  "[audio-mp3] streamed"
check "kernel PASS banner"          "[audio-mp3] PASS"

# --- the ground truth: the captured WAV must be NON-SILENT ----------
if [ ! -s "$WAV" ]; then
    echo "[test_hda_mp3] FAIL: QEMU produced no WAV file at $WAV" >&2
    fail=1
else
    PEAK=$(python3 - "$WAV" <<'PY'
import sys, struct, wave
path = sys.argv[1]
peak = 0
nframes = 0
rms = 0.0
try:
    w = wave.open(path, 'rb')
    sw = w.getsampwidth()
    nframes = w.getnframes()
    data = w.readframes(nframes)
    w.close()
    if sw == 2:
        n = len(data) // 2
        if n:
            vals = struct.unpack("<%dh" % n, data[:n*2])
            peak = max(abs(v) for v in vals)
            rms = (sum(v*v for v in vals) / n) ** 0.5
    elif sw == 1:
        peak = max(abs(b - 128) for b in data) if data else 0
    else:
        peak = max(data) if data else 0
except Exception:
    raw = open(path, 'rb').read()
    body = raw[44:]
    if body:
        n = len(body)//2
        if n:
            vals = struct.unpack("<%dh" % n, body[:n*2])
            peak = max(abs(v) for v in vals)
            rms = (sum(v*v for v in vals) / n) ** 0.5
        nframes = n
print("%d %d %.1f" % (peak, nframes, rms))
PY
)
    PEAK_VAL=$(echo "$PEAK" | awk '{print $1}')
    NFRAMES=$(echo "$PEAK" | awk '{print $2}')
    RMS_VAL=$(echo "$PEAK" | awk '{print $3}')
    echo "[test_hda_mp3] captured WAV: $NFRAMES frames, peak |sample| = $PEAK_VAL, RMS = $RMS_VAL"
    if [ "${PEAK_VAL:-0}" -ge 1000 ]; then
        echo "[test_hda_mp3] PASS: captured WAV is NON-SILENT (real decoded MP3 samples)"
    else
        echo "[test_hda_mp3] FAIL: captured WAV is silent/zero (peak=$PEAK_VAL)" >&2
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hda_mp3] FAIL"
    exit 1
fi

echo "[test_hda_mp3] PASS — native MP3 decoded in-kernel and played via HDA stream DMA; host WAV captured non-silent PCM"
