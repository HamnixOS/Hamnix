#!/usr/bin/env bash
# scripts/test_block_layer_write.sh — M16.119 verification: AHCI +
# NVMe drivers are now registered with the kernel block layer's
# BlockDeviceOps vtable, so writes submitted via blk_write_sectors()
# reach the real controllers and round-trip through blk_read_sectors()
# byte-for-byte.
#
# We boot QEMU once with BOTH an AHCI disk and an NVMe namespace
# attached. The driver-side smoke tests (M16.118) already validate
# that the driver-level WRITE primitives work; the new tests in
# drivers/ata/ahci.ad::_ahci_blk_smoke_test and
# drivers/nvme/nvme.ad::_nvme_blk_smoke_test verify the SAME bytes
# round-trip through the block-layer vtable (i.e.
# blk_write_sectors(slot, lba, 1, buf) -> blk_read_sectors(slot, lba,
# 1, buf) -> byte equality).
#
# Assertion markers (printed by the kernel after a successful
# round-trip):
#
#   "[ahci] registered as block slot="
#   "[blk] write sd0 LBA=1 OK"
#   "[blk] readback sd0 matches"
#   "[nvme] registered as block slot="
#   "[blk] write nvme0n1 LBA=1 OK"
#   "[blk] readback nvme0n1 matches"
#
# A mismatch banner ("[ahci] blk-smoke: MISMATCH" or
# "[nvme] blk-smoke: MISMATCH") in the log is treated as a hard fail
# regardless of which markers above are present.
#
# Disk images are tmpfile'd per run (dd zero, 1 MiB each, MBR
# signature planted at LBA 0 bytes 510..511 so the existing READ
# smoke tests at LBA 0 keep passing). LBA 1 is the target sector for
# both disks; this is the same LBA the driver-level write smoke tests
# touch, so we're not re-verifying anything the M16.118 tests already
# cover — we're proving the vtable path lands on the right
# controller.
#
# Build lock: source `_build_lock.sh` ONCE here (build_user /
# build_modules / build_initramfs each take the same lock, so don't
# also bash a script that re-takes it).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_block_layer_write] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
ENABLE_NVME_SELFTEST=1 INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_block_layer_write] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_block_layer_write] (3/4) Mint 1 MiB disks for AHCI + NVMe"
AHCI_DISK=$(mktemp --suffix=.blklayer-ahci-disk)
NVME_DISK=$(mktemp --suffix=.blklayer-nvme-disk)
dd if=/dev/zero of="$AHCI_DISK" bs=1M count=1 status=none
dd if=/dev/zero of="$NVME_DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$AHCI_DISK" bs=1 seek=510 conv=notrunc status=none
printf '\x55\xaa' | dd of="$NVME_DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$AHCI_DISK" "$NVME_DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_block_layer_write] (4/4) Boot QEMU with -device ahci + -device nvme"
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$AHCI_DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -drive if=none,file="$NVME_DISK",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnix1234 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_block_layer_write] --- captured (blk/ahci/nvme lines) ---"
grep -E '\[blk\]|\[ahci\]|\[nvme\]|blk-smoke|blk: register' "$LOG" || true
echo "[test_block_layer_write] --- end ---"

fail=0
# AHCI side — registration + block-layer round-trip PASS markers.
for needle in \
    "[ahci] controller found" \
    "[ahci] MBR signature OK" \
    "[ahci] registered as block slot=" \
    "[blk] write sd0 LBA=1 OK" \
    "[blk] readback sd0 matches"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_block_layer_write] OK (ahci): '$needle'"
    else
        echo "[test_block_layer_write] MISS (ahci): '$needle'"
        fail=1
    fi
done

# NVMe side — registration + block-layer round-trip PASS markers.
for needle in \
    "[nvme] controller ready" \
    "[nvme] MBR signature OK" \
    "[nvme] registered as block slot=" \
    "[blk] write nvme0n1 LBA=1 OK" \
    "[blk] readback nvme0n1 matches"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_block_layer_write] OK (nvme): '$needle'"
    else
        echo "[test_block_layer_write] MISS (nvme): '$needle'"
        fail=1
    fi
done

# Hard-fail if either driver's mismatch banner fired — that means the
# blk_write_sectors path returned 0 (looked successful) but the bytes
# didn't survive the round-trip.
if grep -F -q "[ahci] blk-smoke: MISMATCH" "$LOG"; then
    echo "[test_block_layer_write] AHCI blk-smoke MISMATCH banner present - FAIL"
    fail=1
fi
if grep -F -q "[nvme] blk-smoke: MISMATCH" "$LOG"; then
    echo "[test_block_layer_write] NVMe blk-smoke MISMATCH banner present - FAIL"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_block_layer_write] FAIL (qemu rc=$rc)"
    echo "[test_block_layer_write] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_block_layer_write] PASS"
