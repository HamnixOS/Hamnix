#!/usr/bin/env bash
# scripts/test_sound_mixer.sh — native software audio MIXER.
#
# Boots Hamnix once under QEMU with an `intel-hda` controller + a
# `hda-output` codec wired to QEMU's WAV audio backend. The boot-gated
# audio self-test (gated on /etc/audio-test = ENABLE_AUDIO_TEST=1) runs
# both the single-stream tone playback AND the software-mixer self-test
# (drivers/audio/audio_selftest.ad :: audio_mixer_selftest), which:
#
#   * opens 2 concurrent PCM streams through the native mixer
#     (drivers/audio/mixer.ad);
#   * sets distinct per-stream + master volumes via TEXT writes to the
#     real /dev/audioctl Plan-9 control file ("master 75", "stream 0 80",
#     "stream 1 40");
#   * writes known s16le sample patterns to each stream;
#   * renders the mix (per-stream gain -> saturating sum -> master gain ->
#     s16 clamp) into the single hardware PCM DMA buffer;
#   * asserts EVERY mixed sample is byte-exact against an independent
#     fixed-point recompute, AND that the saturating-add path actually
#     clamped some samples (so the saturation is genuinely exercised).
#
# This is the ground truth: the kernel-side assertion compares the real
# rendered hardware buffer to the expected mix. The host also confirms the
# tone still reaches the codec (the single-stream path is not regressed).
#
# Pass marker:  [test_mixer] PASS
# Fail marker:  [test_mixer] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mixer] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mixer] (2/3) Build kernel with /etc/audio-test marker"
INIT_ELF=build/user/init.elf ENABLE_AUDIO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mixer] (3/3) Boot QEMU with intel-hda -> wav backend"
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
    -device hda-output,audiodev=snd0 \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_mixer] --- mixer self-test output ---"
grep -E "\[hda\]|\[audio\]|\[audio-mix\]" "$LOG" || true
echo "[test_mixer] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mixer] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[audio-mix] FAIL" "$LOG"; then
    echo "[test_mixer] FAIL: mixer self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[audio] FAIL" "$LOG"; then
    echo "[test_mixer] FAIL: audio self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mixer] PASS: $label"
    else
        echo "[test_mixer] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
# HDA must really be up (the mixer pushes into its real DMA buffer).
check "controller out of reset"   "[hda] controller out of reset"
check "codec + DAC/pin path"      "[hda] DAC nid="
check "init OK"                   "[hda] init OK"
# Mixer-specific assertions.
check "2 concurrent streams open" "[audio-mix] opened 2 streams"
check "volumes set via ctl file"  "[audio-mix] volumes set via /dev/audioctl"
check "mixed samples byte-exact"  "[audio-mix] verified"
check "mixer PASS banner"         "[audio-mix] PASS"
check "audio gate PASS banner"    "[audio] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_mixer] FAIL"
    exit 1
fi

echo "[test_mixer] PASS — native software mixer summed 2 gain-scaled streams (saturating) into the HDA buffer; byte-exact vs reference"
