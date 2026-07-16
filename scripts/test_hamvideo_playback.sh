#!/usr/bin/env bash
# scripts/test_hamvideo_playback.sh — on-device video DECODE + wsys-BLIT gate.
#
# The sibling of scripts/test_hamaudio_playback.sh (#321), built on the SAME
# proven, deterministic, headless path: run a guest program AS /init (no DE, no
# compositor, no mouse — none of the flaky windowed-launch machinery), with the
# royalty-free clip planted in the initramfs, and boot QEMU with `-kernel`.
#
# It proves the hamvideo player's real media path, guest-program-first:
#   user/hamvideoselftest.ad (userland /init)
#     STAGE 1  read /usr/share/videos/test.hmjv
#              -> lib/mjpegdemux demux -> geometry / fps / frame index
#              -> lib/jpeg decode EVERY frame -> assert each is NON-BLANK
#     STAGE 2  open /dev/wsys, newwindow, and UPLOAD a full-resolution decoded
#              frame (256x192 RGBA8888) via ONE 'I'-verb sys_write to draw/ctl.
#              The kernel delivers that write as 4 KiB chunks; the devwsys
#              'I'-verb STREAMING REASSEMBLY fix stores the whole frame. The
#              write returns the full byte count ONLY when reassembly+store
#              succeeded — before the fix the identical oversized write returned
#              -EINVAL. So `blit_ret == expect` is a precise on-device
#              regression gate on the kernel fix, with no window paint required.
#
# Pass criteria (objective, headless):
#   * the guest demuxed the shipped clip (30 frames @ 256x192, 10 fps);
#   * lib/jpeg decoded ALL 30 frames to NON-BLANK content on the native target;
#   * the full-frame 'I'-verb blit round-tripped the kernel reassembly
#     (blit_ret == 196624), proving the chunked-'I' kernel fix on-device;
#   * no kernel panic.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hamvideo_playback] (1/3) Build userland (hamvideoselftest + init)"
bash scripts/build_user.sh >/dev/null

# Make sure the fixture clip exists (deterministic regen).
[ -s tests/fixtures/videos/test.hmjv ] || python3 scripts/gen_test_video.py >/dev/null

echo "[test_hamvideo_playback] (2/3) Build kernel with hamvideoselftest as /init + clip in initramfs"
INIT_ELF=build/user/hamvideoselftest.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hamvideo_playback] (3/3) Boot QEMU (-kernel, headless) — guest decodes + blits"
set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hamvideo_playback] --- guest output ---"
grep -E "\[hamvideo-selftest\]" "$LOG" || true
echo "[test_hamvideo_playback] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_hamvideo_playback] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi
if grep -aqi 'kernel panic\|#UD\|triple fault' "$LOG"; then
    echo "[test_hamvideo_playback] FAIL: panic/fault in serial log" >&2
    fail=1
else
    echo "[test_hamvideo_playback] PASS: no panic (kernel 'I'-reassembly is boot-safe)"
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_hamvideo_playback] PASS: $label"
    else
        echo "[test_hamvideo_playback] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
# STAGE 1 — on-device demux + decode.
check "guest demuxed the clip (30 frames)"       "[hamvideo-selftest] frames 30"
check "guest decoded all 30 frames"              "[hamvideo-selftest] decoded 30"
check "all 30 decoded frames NON-BLANK"          "[hamvideo-selftest] nonblank 30"
# STAGE 2 — on-device 'I'-verb chunked reassembly (the kernel fix).
check "full-frame 'I' blit round-tripped kernel" "[hamvideo-selftest] blit_ret 196624 expect 196624"
check "'I'-verb frame stored (fix proven)"        "[hamvideo-selftest] blit_ok"
check "self-test overall PASS"                    "[hamvideo-selftest] DONE PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamvideo_playback] FAIL"
    exit 1
fi
echo "[test_hamvideo_playback] PASS — the guest decoded the shipped Motion-JPEG clip to non-blank frames on-device AND a full-resolution frame round-tripped the devwsys 'I'-verb chunked-reassembly kernel fix"
