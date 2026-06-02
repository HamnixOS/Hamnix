#!/usr/bin/env bash
# scripts/test_fat_dirgrow.sh — FAT directory cross-cluster growth test.
#
# Boots the kernel once with /etc/fat-dirgrow-test planted
# (ENABLE_FAT_DIRGROW_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.dgr calls fat_dirgrow_selftest() (fs/fat.ad),
# which:
#
#   * resolves the AHCI disk through the block layer with
#     find_blockdev("sd0"),
#   * lays down a fresh tiny FAT32 volume on it with sectors_per_cluster=1
#     (512-byte cluster -> only 16 directory entries per cluster),
#   * mounts it via fat_init(),
#   * fat_creates 24 files in the ROOT directory — more than fit in one
#     16-entry cluster — forcing the root dirent region to grow into a
#     freshly-allocated, chain-linked SECOND cluster,
#   * asserts the root's FAT chain head now points at a 2nd cluster, then
#   * re-looks-up every one of the 24 files by name; files past index 15
#     live in the grown cluster, so a hit there proves the chain-follow
#     scan + grow-on-exhaustion link in _fat_dir_find_free_slot.
#
# A PASS proves FAT directories grow across multiple clusters — a real
# FAT capability (Linux/Windows directories aren't capped at one cluster).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [FAT_DIRGROW] PASS
# Fail marker:  [FAT_DIRGROW] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_fat_dirgrow] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fat_dirgrow] (2/4) Build kernel with /etc/fat-dirgrow-test marker"
INIT_ELF=build/user/init.elf ENABLE_FAT_DIRGROW_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fat_dirgrow] (3/4) Mint a 64 MiB SATA scratch disk"
DISK=$(mktemp --suffix=.fat-dirgrow-disk)
# 64 MiB scratch disk — far larger than the 256 KiB volume the self-test
# lays down. Content is don't-care (the test overwrites the system area),
# but plant a 0x55AA at bytes 510..511 so the earlier ahci_smoke_test()
# MBR-signature check stays happy.
dd if=/dev/zero of="$DISK" bs=1M count=64 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fat_dirgrow] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
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

echo "[test_fat_dirgrow] --- captured (FAT_DIRGROW lines) ---"
grep -E '\[FAT_DIRGROW\]' "$LOG" || true
echo "[test_fat_dirgrow] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fat_dirgrow] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[FAT_DIRGROW] FAIL" "$LOG"; then
    echo "[test_fat_dirgrow] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[FAT_DIRGROW] self-test reported FAIL" "$LOG"; then
    echo "[test_fat_dirgrow] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_fat_dirgrow] PASS: $label"
    else
        echo "[test_fat_dirgrow] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[FAT_DIRGROW] self-test start"
check "fat-dirgrow self-test PASS" "[FAT_DIRGROW] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_fat_dirgrow] FAIL"
    exit 1
fi

echo "[test_fat_dirgrow] PASS — FAT directories grow across multiple clusters (24 files created + re-looked-up across a grown root dir cluster chain)"
