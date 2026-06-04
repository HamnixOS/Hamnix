#!/usr/bin/env bash
# scripts/test_virtio_blk_dwz.sh — virtio-blk FLUSH / DISCARD / WRITE_ZEROES.
#
# Boots the kernel once with /etc/virtio-blk-dwz-test planted
# (ENABLE_VBLK_DWZ_TEST=1) and a QEMU virtio-blk disk that ADVERTISES
# discard + flush (-drive ...,discard=unmap, default writeback cache).
# init/main.ad at boot:37.vblkdwz calls virtio_blk_dwz_selftest()
# (drivers/block/virtio_blk.ad), which drives REAL virtio-blk requests
# against the emulated device:
#
#   * negotiates VIRTIO_BLK_F_FLUSH / F_DISCARD / F_WRITE_ZEROES and reads
#     the discard/write-zeroes config limits,
#   * seeds 4 sectors with a non-zero pattern, issues a REAL FLUSH
#     (VIRTIO_BLK_T_FLUSH, type 4) and confirms the data is still readable
#     -> [virtio-blk] PASS flush,
#   * issues a REAL WRITE_ZEROES (VIRTIO_BLK_T_WRITE_ZEROES, type 13) and
#     reads the region back, asserting every byte is now zero
#     -> [virtio-blk] PASS write-zeroes,
#   * issues a REAL DISCARD (VIRTIO_BLK_T_DISCARD, type 11) and asserts the
#     device returned status OK -> [virtio-blk] PASS discard.
#
# Each request checks the device status byte (OK / IOERR / UNSUPP); no
# faked completions.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass markers: [virtio-blk] PASS flush / PASS write-zeroes / PASS discard
# Fail markers: [virtio-blk] FAIL / dwz self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_virtio_blk_dwz] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_virtio_blk_dwz] (2/4) Build kernel with /etc/virtio-blk-dwz-test marker"
INIT_ELF=build/user/init.elf ENABLE_VBLK_DWZ_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_virtio_blk_dwz] (3/4) Mint a virtio scratch disk with a valid MBR sig"
DISK=$(mktemp --suffix=.vblk-dwz-disk)
# 4 MiB scratch disk. The self-test seeds + reads LBA 96..99, so on-disk
# content is don't-care — but plant 0x55 0xAA at bytes 510..511 so the
# early FAT/partition probe sees a well-formed signature.
dd if=/dev/zero of="$DISK" bs=1M count=4 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_virtio_blk_dwz] (4/4) Boot QEMU with virtio-blk advertising discard/flush"
set +e
# if=virtio attaches a TRANSITIONAL virtio-blk (PCI device-id 0x1001) that
# the legacy driver probes; discard=unmap makes QEMU offer
# VIRTIO_BLK_F_DISCARD + F_WRITE_ZEROES, and the default writeback cache
# makes it offer VIRTIO_BLK_F_FLUSH.
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw,discard=unmap,cache=writeback \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_virtio_blk_dwz] --- captured (virtio-blk lines) ---"
grep -E 'virtio-blk' "$LOG" || true
echo "[test_virtio_blk_dwz] --- end ---"
# (the wider 'virtio-blk' grep above keeps the device-config + per-request
#  status diagnostics visible alongside the bracketed [virtio-blk] banners)

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_virtio_blk_dwz] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "status=255" "$LOG"; then
    echo "[test_virtio_blk_dwz] NOTE: status=255 seen — possible host-load TCG flake" >&2
fi

if grep -qF "[virtio-blk] dwz FAIL" "$LOG"; then
    echo "[test_virtio_blk_dwz] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[virtio-blk] dwz self-test reported FAIL" "$LOG"; then
    echo "[test_virtio_blk_dwz] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_virtio_blk_dwz] PASS: $label"
    else
        echo "[test_virtio_blk_dwz] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"        "[virtio-blk] dwz self-test start"
check "FLUSH"                "[virtio-blk] PASS flush"
check "WRITE_ZEROES"         "[virtio-blk] PASS write-zeroes"
check "DISCARD"              "[virtio-blk] PASS discard"
check "dwz self-test PASS"   "[virtio-blk] dwz PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_virtio_blk_dwz] FAIL"
    exit 1
fi

echo "[test_virtio_blk_dwz] PASS — virtio-blk FLUSH (type 4), WRITE_ZEROES (type 13, readback all-zero) and DISCARD (type 11) all driven against the emulated device with real status-byte checking"
