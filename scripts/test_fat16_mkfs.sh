#!/usr/bin/env bash
# scripts/test_fat16_mkfs.sh — kernel-side FAT16 mkfs formatter test.
#
# Boots the kernel once with /etc/fat16-mkfs-test planted
# (ENABLE_FAT16_MKFS_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.fmk16 calls fat16_mkfs_selftest()
# (fs/fat_mkfs.ad), which:
#
#   * resolves the AHCI disk THROUGH the block layer with
#     find_blockdev("sd0"),
#   * formats a fresh 128 MiB volume onto it via fat_mkfs(slot, 128).
#     With 16 KiB clusters that yields ~8188 data clusters, which is
#     above the 4084 FAT12 ceiling, so the formatter produces a FAT16
#     volume (BPB + two seeded FAT copies + zeroed root dir),
#   * reads the boot sector + first FAT sector back through the GENERIC
#     blk_read_sectors() vtable and verifies the BPB fields (0x55AA sig,
#     bytes/sector, sectors/cluster, "FAT16   " fs-type string) and the
#     16-bit FAT[0]/FAT[1] seed (entry0 low byte 0xF8, entry1 0xFFFF).
#
# A PASS proves the formatter writes valid, self-consistent on-disk FAT16
# structures that round-trip through the same generic block layer.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [FAT16_MKFS] PASS
# Fail marker:  [FAT16_MKFS] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_fat16_mkfs] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fat16_mkfs] (2/4) Build kernel with /etc/fat16-mkfs-test marker"
INIT_ELF=build/user/init.elf ENABLE_FAT16_MKFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fat16_mkfs] (3/4) Mint a 256 MiB SATA scratch disk"
DISK=$(mktemp --suffix=.fat16-mkfs-disk)
# 256 MiB scratch disk — comfortably larger than the 128 MiB volume the
# self-test formats. Content is don't-care (the formatter overwrites the
# system area), but plant a 0x55AA at bytes 510..511 so the earlier
# ahci_smoke_test() MBR-signature check stays happy.
dd if=/dev/zero of="$DISK" bs=1M count=256 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fat16_mkfs] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_fat16_mkfs] --- captured (FAT16_MKFS lines) ---"
grep -E '\[FAT16_MKFS\]|fat_mkfs:' "$LOG" || true
echo "[test_fat16_mkfs] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fat16_mkfs] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[FAT16_MKFS] FAIL" "$LOG"; then
    echo "[test_fat16_mkfs] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[FAT16_MKFS] self-test reported FAIL" "$LOG"; then
    echo "[test_fat16_mkfs] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_fat16_mkfs] PASS: $label"
    else
        echo "[test_fat16_mkfs] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[FAT16_MKFS] self-test start"
check "format completed"          "fat_mkfs: FAT16 format complete"
check "fat16-mkfs self-test PASS"  "[FAT16_MKFS] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_fat16_mkfs] FAIL"
    exit 1
fi

echo "[test_fat16_mkfs] PASS — kernel-side FAT16 formatter writes a valid, round-trippable FAT16 volume (BPB + seeded FAT + root dir) verified through the generic block layer"
