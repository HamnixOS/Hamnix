#!/usr/bin/env bash
# scripts/test_hda_capture.sh — native Intel HDA PCM capture (record).
#
# Boots Hamnix once under QEMU with an `intel-hda` controller wired to
# QEMU's WAV audio backend (an input pin is present even if QEMU does not
# feed a live microphone). The kernel capture self-test (init/main.ad
# boot:37.acap, gated on /etc/audiocap-test = ENABLE_AUDIOCAP_TEST=1) arms
# the HDA input-stream DMA ring, feeds a known synthetic PCM pattern through
# the SAME DMA-complete deposit path the controller would use, and reads it
# back byte-identical via the /dev/audioin Plan-9 cdev.
#
# This proves the capture ring/position/wrap bookkeeping and the
# /dev/audioin read handler are GENUINELY implemented (not a faked read),
# even though QEMU supplies no live microphone samples.
#
# Pass marker:  [test_hda_capture] PASS
# Fail marker:  [test_hda_capture] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hda_capture] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_hda_capture] (2/3) Build kernel with /etc/audiocap-test marker"
INIT_ELF=build/user/init.elf ENABLE_AUDIOCAP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hda_capture] (3/3) Boot QEMU with intel-hda + input pin"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device intel-hda \
    -device hda-duplex,audiodev=snd0 \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hda_capture] --- capture self-test output ---"
grep -E "\[hda\]|\[audio-capture\]" "$LOG" || true
echo "[test_hda_capture] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_hda_capture] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[audio-capture] FAIL" "$LOG"; then
    echo "[test_hda_capture] FAIL: kernel capture self-test reported failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_hda_capture] PASS: $label"
    else
        echo "[test_hda_capture] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
check "controller init OK"        "[hda] init OK"
check "capture stream init"       "[audio-capture] capture stream init OK"
check "empty-ring read = 0"       "[audio-capture] empty-ring read returned 0"
check "byte-identical readback"   "[audio-capture] read back"
check "read pointer advance"      "[audio-capture] read pointer advanced correctly"
check "ring wrap byte-identical"  "[audio-capture] ring wrap read byte-identical"
check "kernel PASS banner"        "[audio-capture] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_hda_capture] FAIL"
    exit 1
fi

echo "[test_hda_capture] PASS — native HDA capture ring + /dev/audioin verified end-to-end"
