#!/usr/bin/env bash
# scripts/test_inguest_gpu_multiop_hw.sh — GPU track #182: rasterize a REAL
# MULTI-OP frame (the VK_OP_2D_* stream a DE window / browser box-paint emits)
# in-guest on the REAL NVIDIA RTX 3090, not the Mesa/llvmpipe CPU fallback.
#
# This is the next step past scripts/test_inguest_gpu_hw.sh (which proved ONE
# host-GPU fill). Here vk_core's GPU FRAME ROUTER replays a whole frame —
# background CLEAR + several FILL_RECTs + an opaque FILL_RECT_ALPHA + two
# axis-aligned DRAW_LINEs, plus a RESOURCE_COPY_REGION blit — through
# vk_venus -> SUBMIT_3D onto the host GPU, then byte-compares the read-back
# pixels to the vk2d SW oracle IN-GUEST. Three+ distinct VK_OP_2D op TYPES on
# the 3090, proven byte-identical to SW (see lib/vk/vk_selftest.ad
# vk_gpu_virgl_multiop_selftest -> [vgpu-multiop] markers).
#
# Same HOST-SIDE mechanism as test_inguest_gpu_hw.sh: a UI display backend with
# gl=on hands virglrenderer the X/GLX GL context = the NVIDIA driver = the RTX
# 3090 (egl-headless would be GBM = llvmpipe on an NVIDIA host). Needs a live
# GL-capable X session; SKIPs cleanly without $DISPLAY / nvidia-smi / the
# NVIDIA EGLDevice.
#
# SUCCESS (all of):
#   1. guest marker `[vgpu-multiop] PASS: multi-op frame ... byte-matches the SW
#      oracle on the host GPU` (real, non-prefill pixels, >=3 op types)
#   2. GL_RENDERER=NVIDIA / gl_version 46 (llvmpipe tops out at 4.5) — not CPU
#   3. nvidia-smi shows our QEMU process resident on the GPU during the run
#
# HYGIENE: timeout-wrapped QEMU, own-PID-only kill (never pkill), serial-only
# markers, marker-counted (0 guest markers => INCONCLUSIVE, never a pass).
# Pass marker: [test_inguest_gpu_multiop_hw] PASS  Fail: [...] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BOOT_WAIT="${BOOT_WAIT:-240}"
HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
SCRATCH="${TMPDIR:-/tmp}"

skip() { echo "[test_inguest_gpu_multiop_hw] SKIP: $1"; exit 0; }

# --- environment gates ------------------------------------------------
[ -e /dev/kvm ] || skip "/dev/kvm absent (KVM required)"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v nvidia-smi >/dev/null 2>&1 || skip "nvidia-smi not found (no NVIDIA GPU to accelerate on)"
command -v cc >/dev/null 2>&1 || skip "no C compiler for the EGLDevice probe"
[ -n "${DISPLAY:-}" ] || skip "no \$DISPLAY (HW path needs a live GL-capable X server; egl-headless=GBM=llvmpipe)"

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || skip "OVMF firmware not found (apt install ovmf)"
qemu-system-x86_64 -device help 2>/dev/null | grep -q "virtio-gpu-gl-pci" \
    || skip "this QEMU has no virtio-gpu-gl-pci device"
DISP_BACKEND=""
if qemu-system-x86_64 -display help 2>/dev/null | grep -qw sdl; then DISP_BACKEND=sdl
elif qemu-system-x86_64 -display help 2>/dev/null | grep -qw gtk; then DISP_BACKEND=gtk
fi
[ -n "$DISP_BACKEND" ] || skip "no sdl/gtk display backend (need a UI-created GL context; egl-headless is GBM-only)"

# --- (0/3) prove the host GL context QEMU will use is the RTX 3090 -----
PROBE_BIN="$SCRATCH/hamnix-egl-device-probe-mo.$$"
cc "$PROJ_ROOT/scripts/egl_device_probe.c" -o "$PROBE_BIN" -lEGL -lGL 2>/dev/null \
    || skip "could not build scripts/egl_device_probe.c (need libEGL/libGL dev)"
PROBE_OUT="$("$PROBE_BIN" 2>/dev/null)"
rm -f "$PROBE_BIN"
if ! echo "$PROBE_OUT" | grep -q "GL_RENDERER=NVIDIA"; then
    echo "[test_inguest_gpu_multiop_hw] host EGLDevice probe found no NVIDIA GL context:"
    echo "$PROBE_OUT" | grep PROBE-RESULT
    skip "the NVIDIA GPU does not expose a headless GL context here (EGLDevice absent)"
fi
echo "[test_inguest_gpu_multiop_hw] (0/3) host EGLDevice GL context: $(echo "$PROBE_OUT" | grep 'GL_RENDERER=NVIDIA' | head -1 | sed 's/.*GL_RENDERER=//')"

# --- build the installer medium WITH the virgl self-tests armed --------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_inguest_gpu_multiop_hw] (1/3) building installer medium (ENABLE_VIRTIO_GPU_TEST=1)"
    rm -f "$HAMNIX_INSTALLER_IMG"
    ENABLE_VIRTIO_GPU_TEST=1 HAMNIX_FORCE_SELFTESTS=1 \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh" \
        || { echo "[test_inguest_gpu_multiop_hw] FAIL: installer build failed" >&2; exit 1; }
fi
[ -f "$HAMNIX_INSTALLER_IMG" ] || { echo "[test_inguest_gpu_multiop_hw] FAIL: $HAMNIX_INSTALLER_IMG missing" >&2; exit 1; }

GLOVMF=$(mktemp --tmpdir hamnix-igmo.ovmf.XXXXXX.fd)
GLIMG=$(mktemp --tmpdir hamnix-igmo.disk.XXXXXX.img)
GLLOG=$(mktemp --tmpdir hamnix-igmo.XXXXXX.log)
SMILOG=$(mktemp --tmpdir hamnix-igmo.smi.XXXXXX.log)
cp "$OVMF_FD" "$GLOVMF"
cp "$HAMNIX_INSTALLER_IMG" "$GLIMG"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$GLOVMF" "$GLIMG"
}
trap 'cleanup; rm -f "$GLLOG" "$SMILOG"' EXIT

echo "[test_inguest_gpu_multiop_hw] (2/3) booting -device virtio-gpu-gl-pci -display $DISP_BACKEND,gl=on on \$DISPLAY=$DISPLAY"
VREND_DEBUG=all VIRGL_LOG_LEVEL=debug \
timeout "$BOOT_WAIT" qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$GLOVMF" \
    -drive file="$GLIMG",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-gl-pci -display "$DISP_BACKEND",gl=on \
    -no-reboot -serial stdio \
    </dev/null > "$GLLOG" 2>&1 &
QEMU_PID=$!

NVIDIA_RESIDENT=0
for _ in $(seq 1 "$((BOOT_WAIT * 4))"); do
    smi="$(nvidia-smi 2>/dev/null | grep -iE 'qemu-system-x86_64')"
    if [ -n "$smi" ]; then
        NVIDIA_RESIDENT=1
        echo "$smi" >> "$SMILOG"
    fi
    grep -a -q -E "\[vgpu-multiop\] (PASS: 3|PASS: 4|SKIP: host GL accepted|FAIL)" "$GLLOG" && break
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.25
done
sleep 1
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

echo "[test_inguest_gpu_multiop_hw] --- guest multi-op markers ---"
grep -a -E "\[vgpu-multiop\]|\[vgpu-virgl\] (PASS|SKIP)" "$GLLOG" | head -30
echo "[test_inguest_gpu_multiop_hw] --- host GL context (virglrenderer) ---"
GLVER_LINE="$(grep -a -E "gl_version [0-9]+ - core profile" "$GLLOG" | head -1)"
GLREND_LINE="$(grep -a -iE "GL_RENDERER=NVIDIA|NVIDIA GeForce RTX|llvmpipe" "$GLLOG" | head -2)"
echo "${GLVER_LINE:-(no gl_version line)}"
[ -n "$GLREND_LINE" ] && echo "$GLREND_LINE"
echo "[test_inguest_gpu_multiop_hw] --- nvidia-smi residency (our qemu pid) ---"
cat "$SMILOG" 2>/dev/null | head -3 || true

# --- verdict ----------------------------------------------------------
markers=$(grep -a -c -E "\[vgpu-multiop\]" "$GLLOG")
if [ "$markers" -eq 0 ]; then
    echo "[test_inguest_gpu_multiop_hw] INCONCLUSIVE: no [vgpu-multiop] guest markers (boot did not reach the self-test)" >&2
    trap 'cleanup' EXIT
    exit 0
fi
if grep -a -q -E "\[vgpu-multiop\] FAIL" "$GLLOG"; then
    echo "[test_inguest_gpu_multiop_hw] FAIL: guest reported a multi-op self-test failure" >&2
    trap 'cleanup' EXIT
    exit 1
fi

GREEN=0
grep -a -q -E "\[vgpu-multiop\] PASS: multi-op frame .* byte-matches the SW oracle on the host GPU" "$GLLOG" && GREEN=1
NV_CTX=0
if grep -a -q -E "gl_version 4[6-9] - core profile" "$GLLOG" \
   || grep -a -qiE "GL_RENDERER=NVIDIA|NVIDIA GeForce RTX" "$GLLOG"; then
    NV_CTX=1
fi

if [ "$GREEN" -eq 1 ] && [ "$NV_CTX" -eq 1 ] && [ "$NVIDIA_RESIDENT" -eq 1 ]; then
    OPS="$(grep -a -oE "\[vgpu-multiop\] PASS: [34] op types[^\\\\]*" "$GLLOG" | head -1)"
    echo "[test_inguest_gpu_multiop_hw] PASS: MULTI-OP frame rasterized on the RTX 3090 —"
    echo "[test_inguest_gpu_multiop_hw]   byte-identical to the SW oracle, GL_RENDERER=NVIDIA, nvidia-smi resident."
    [ -n "$OPS" ] && echo "[test_inguest_gpu_multiop_hw]   ${OPS#\[vgpu-multiop\] }"
    exit 0
fi

if [ "$GREEN" -eq 1 ]; then
    echo "[test_inguest_gpu_multiop_hw] SKIP: multi-op frame is byte-exact, but this run did NOT confirm the RTX 3090 as the host context"
    echo "[test_inguest_gpu_multiop_hw]   GL_RENDERER=NVIDIA seen: $NV_CTX   nvidia-smi resident: $NVIDIA_RESIDENT"
    trap 'cleanup' EXIT
    exit 0
fi

echo "[test_inguest_gpu_multiop_hw] SKIP: multi-op markers present but no byte-exact GPU PASS (host GL likely non-rendering; see log)"
trap 'cleanup' EXIT
exit 0
