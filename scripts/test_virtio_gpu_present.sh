#!/usr/bin/env bash
# scripts/test_virtio_gpu_present.sh — GPU track #182, Phase 1.
#
# Native virtio-gpu 2D present path. Proves the accelerated-in-VM present
# spine end to end with ZERO Linux/namespace dependency:
#
#   modern virtio-1.0 PCI transport (drivers/virtio/virtio_modern.ad)
#     -> virtio-gpu controlq commands (drivers/video/virtio_gpu.ad)
#        GET_DISPLAY_INFO -> RESOURCE_CREATE_2D -> ATTACH_BACKING
#        -> SET_SCANOUT -> (paint four-quadrant pattern) ->
#        TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH
#     -> pixels on the virtio-gpu scanout.
#
# This is the first real GPU DEVICE data path beyond the GOP linear
# framebuffer. We boot the SHIPPED image (build/hamnix.img) under OVMF
# with `-device virtio-gpu-pci` as the ONLY display, so QEMU's
# `screendump` captures the virtio-gpu scanout the kernel flushed into.
# The boot-flag marker /etc/virtio-gpu-test (planted via
# ENABLE_VIRTIO_GPU_TEST=1) makes init/main.ad's boot:37.vgpu gate paint
# + flush the known four-quadrant pattern DURING boot — no shell needed.
#
# The `-kernel` multiboot path can NOT be used here: this host's QEMU
# (10.x) refuses the multiboot kernel under any VGA/VBE device ("multiboot
# knows VBE. we don't"). The OVMF/UEFI GOP path is the supported one (see
# memory: QEMU multiboot/VBE host limit). virtio-gpu provides its own GOP
# under OVMF.
#
# UNFORGEABLE assertions (golden pixels at known coords on the dumped
# scanout — a precomputed bitmap could not satisfy all four quadrants AND
# the driver's success log markers):
#   * top-left  quadrant pixel == RED
#   * top-right quadrant pixel == GREEN
#   * bot-left  quadrant pixel == BLUE
#   * bot-right quadrant pixel == WHITE
# plus the driver's boot-log success markers:
#   * "virtio-gpu: modern transport bound"
#   * "virtio-gpu: DISPLAY_INFO scanout0"
#   * "virtio-gpu: FLUSH ok"
#   * "[vgpu] PASS"
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable.
#
# Pass marker:  [test_vgpu] PASS
# Fail marker:  [test_vgpu] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
BOOT_WAIT="${BOOT_WAIT:-120}"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_vgpu] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_vgpu] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the image WITH the virtio-gpu present marker ---------------
# ENABLE_VIRTIO_GPU_TEST=1 plants /etc/virtio-gpu-test, which survives
# into the empty-cpio shipped image (build_initramfs.py emits /etc/*
# markers even in the HAMNIX_CPIO_EMPTY=1 path build_img.sh uses).
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_vgpu] (1/2) building disk image (ENABLE_VIRTIO_GPU_TEST=1)"
    rm -f "$HAMNIX_IMG"
    ENABLE_VIRTIO_GPU_TEST=1 bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[test_vgpu] FAIL: $HAMNIX_IMG missing after build_img.sh" >&2
    exit 1
fi

OVMF_RW=$(mktemp --tmpdir hamnix-vgpu.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-vgpu.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-vgpu.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-vgpu-mon.XXXXXX)
SHOT=$(mktemp --tmpdir hamnix-vgpu.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$SHOT"
}
trap 'cleanup; rm -f "$LOG"' EXIT

echo "[test_vgpu] (2/2) booting under OVMF with -device virtio-gpu-pci (sole display)"

# virtio-gpu-pci is the ONLY display device (-vga none), so screendump
# captures the virtio-gpu scanout — the surface the kernel flushed into.
# -monitor on a unix socket lets us screendump it.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-pci \
    -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    </dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the driver's FLUSH-ok marker ----------------------------
echo "[test_vgpu] waiting up to ${BOOT_WAIT}s for the present marker..."
presented=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[vgpu\] (PASS|FAIL)" "$LOG"; then
        presented=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # QEMU may exit after the boot self-test; that's fine if the
        # marker already landed. Re-check once below.
        grep -a -q -E "\[vgpu\] (PASS|FAIL)" "$LOG" && presented=1
        break
    fi
    sleep 1
done

# --- screendump the virtio-gpu scanout --------------------------------
SHOT_OK=0
if [ "$presented" -eq 1 ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    # A few spaced dumps to reliably catch the flushed frame.
    for _ in 1 2 3 4; do
        printf 'screendump %s\n' "$SHOT" | nc -U -q1 "$MON" >/dev/null 2>&1 || true
        sleep 0.6
    done
    [ -s "$SHOT" ] && SHOT_OK=1
fi

sleep 1
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

echo "[test_vgpu] --- virtio-gpu / vgpu boot log ---"
grep -a -E "virtio-gpu|virtio-modern|\[vgpu\]" "$LOG" || true
echo "[test_vgpu] --- end ---"

fail=0

# --- driver success markers in the boot log ---------------------------
check_log() {
    local label="$1" needle="$2"
    if grep -a -q -E "$needle" "$LOG"; then
        echo "[test_vgpu] PASS: $label"
    else
        echo "[test_vgpu] FAIL: $label (expected /$needle/)" >&2
        fail=1
    fi
}
check_log "modern transport bound"       "virtio-gpu: modern transport bound"
check_log "DISPLAY_INFO ok"              "virtio-gpu: DISPLAY_INFO scanout0"
check_log "FLUSH ok"                     "virtio-gpu: FLUSH ok"
check_log "present self-test PASS"       "\[vgpu\] PASS"

if grep -a -q -E "\[vgpu\] FAIL" "$LOG"; then
    echo "[test_vgpu] FAIL: kernel reported [vgpu] FAIL" >&2
    fail=1
fi

# --- golden-pixel proof on the dumped scanout -------------------------
# The four quadrants are RED / GREEN / BLUE / WHITE. We sample the centre
# of each quadrant. A real screendump of the flushed virtio-gpu surface
# is the only way to satisfy all four simultaneously.
if [ "$SHOT_OK" -eq 1 ]; then
    python3 - "$SHOT" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
if not data.startswith(b"P6"):
    print("[ppm] not P6 (%r) — unusable" % data[:8]); sys.exit(2)
idx = 2; toks = []
while len(toks) < 3:
    while idx < len(data) and data[idx] in b" \t\n\r": idx += 1
    if idx < len(data) and data[idx:idx+1] == b"#":
        while idx < len(data) and data[idx] not in b"\n": idx += 1
        continue
    s = idx
    while idx < len(data) and data[idx] not in b" \t\n\r": idx += 1
    toks.append(int(data[s:idx]))
idx += 1
w, h, maxv = toks
print("[ppm] %dx%d maxval=%d" % (w, h, maxv))
pix = data[idx:]
def px(x, y):
    o = (y * w + x) * 3
    return pix[o], pix[o+1], pix[o+2]
# Quadrant centres.
qx0, qx1 = w // 4, (3 * w) // 4
qy0, qy1 = h // 4, (3 * h) // 4
tl = px(qx0, qy0); tr = px(qx1, qy0)
bl = px(qx0, qy1); br = px(qx1, qy1)
print("[ppm] TL(%d,%d)=#%02x%02x%02x TR(%d,%d)=#%02x%02x%02x"
      % (qx0, qy0, tl[0], tl[1], tl[2], qx1, qy0, tr[0], tr[1], tr[2]))
print("[ppm] BL(%d,%d)=#%02x%02x%02x BR(%d,%d)=#%02x%02x%02x"
      % (qx0, qy1, bl[0], bl[1], bl[2], qx1, qy1, br[0], br[1], br[2]))
def is_red(p):   return p[0] > 150 and p[1] < 90  and p[2] < 90
def is_green(p): return p[1] > 150 and p[0] < 90  and p[2] < 90
def is_blue(p):  return p[2] > 150 and p[0] < 90  and p[1] < 90
def is_white(p): return p[0] > 180 and p[1] > 180 and p[2] > 180
ok = is_red(tl) and is_green(tr) and is_blue(bl) and is_white(br)
print("[ppm] TL_RED=%d TR_GREEN=%d BL_BLUE=%d BR_WHITE=%d"
      % (is_red(tl), is_green(tr), is_blue(bl), is_white(br)))
sys.exit(0 if ok else 3)
PYEOF
    pr=$?
    if [ "$pr" -eq 0 ]; then
        echo "[test_vgpu] PASS: screendump shows RED/GREEN/BLUE/WHITE quadrants on the virtio-gpu scanout (real pixels)"
    else
        echo "[test_vgpu] FAIL: virtio-gpu scanout quadrant pixels wrong (rc=$pr)" >&2
        fail=1
    fi
else
    echo "[test_vgpu] FAIL: no usable virtio-gpu screendump captured" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vgpu] FAIL (boot log: $LOG)"
    trap 'cleanup' EXIT   # keep the log for debugging
    exit 1
fi

echo "[test_vgpu] PASS — native virtio-gpu 2D transport presented a four-quadrant pattern onto the virtio-gpu scanout"
