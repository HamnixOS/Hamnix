#!/usr/bin/env bash
# scripts/test_fat_mkfs.sh — kernel-side FAT12 mkfs formatter test.
#
# Boots the kernel once with /etc/fat-mkfs-test planted
# (ENABLE_FAT_MKFS_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.fmk calls fat_mkfs_selftest() (fs/fat_mkfs.ad),
# which:
#
#   * resolves the AHCI disk THROUGH the block layer with
#     find_blockdev("sd0"),
#   * formats a fresh 32 MiB FAT12 volume onto it via fat_mkfs(slot, 32)
#     (boot sector / BPB + two seeded FAT copies + zeroed root dir),
#   * reads the boot sector + first FAT sector back through the GENERIC
#     blk_read_sectors() vtable and verifies the BPB fields (0x55AA sig,
#     bytes/sector, sectors/cluster, FAT count, root entries, media byte,
#     "FAT12   " fs-type string) and the packed FAT[0]/FAT[1] seed bytes.
#
# A PASS proves the formatter writes valid, self-consistent on-disk FAT12
# structures that round-trip through the same generic block layer ext4/fat
# mount on.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [FAT_MKFS] PASS
# Fail marker:  [FAT_MKFS] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_fat_mkfs] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fat_mkfs] (2/4) Build kernel with /etc/fat-mkfs-test marker"
INIT_ELF=build/user/init.elf ENABLE_FAT_MKFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fat_mkfs] (3/4) Mint a 64 MiB SATA scratch disk"
DISK=$(mktemp --suffix=.fat-mkfs-disk)
# 64 MiB scratch disk — comfortably larger than the 32 MiB volume the
# self-test formats. Content is don't-care (the formatter overwrites the
# system area), but plant a 0x55AA at bytes 510..511 so the earlier
# ahci_smoke_test() MBR-signature check stays happy.
dd if=/dev/zero of="$DISK" bs=1M count=64 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fat_mkfs] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
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

echo "[test_fat_mkfs] --- captured (FAT_MKFS lines) ---"
grep -E '\[FAT_MKFS\]|fat_mkfs:' "$LOG" || true
echo "[test_fat_mkfs] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fat_mkfs] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[FAT_MKFS] FAIL" "$LOG"; then
    echo "[test_fat_mkfs] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[FAT_MKFS] self-test reported FAIL" "$LOG"; then
    echo "[test_fat_mkfs] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_fat_mkfs] PASS: $label"
    else
        echo "[test_fat_mkfs] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"           "[FAT_MKFS] self-test start"
check "format completed"        "fat_mkfs: FAT12 format complete"
check "fat-mkfs self-test PASS" "[FAT_MKFS] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_fat_mkfs] FAIL"
    exit 1
fi

echo "[test_fat_mkfs] PASS — kernel-side FAT12 formatter writes a valid, round-trippable FAT12 volume (BPB + seeded FAT + root dir) verified through the generic block layer"
