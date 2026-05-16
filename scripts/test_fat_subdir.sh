#!/usr/bin/env bash
# scripts/test_fat_subdir.sh - M16.45 verification.
#
# Drives hamsh through:
#
#     cat /mnt/HELLO.TXT             (root-level read, regression)
#     cat /mnt/SUBDIR/NESTED.TXT     (subdir traversal)
#
# and checks the markers from each. Proves fat_lookup's path-
# component walker descends into a directory entry (attr & 0x10)
# rather than rejecting paths with slashes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_fat_subdir] (1/5) Regenerate disk image"
python3 scripts/build_diskimg.py

echo "[test_fat_subdir] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_fat_subdir] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_fat_subdir] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_fat_subdir] (5/5) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cat /mnt/HELLO.TXT\n'
    sleep 1
    printf 'cat /mnt/SUBDIR/NESTED.TXT\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/disk.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_fat_subdir] --- captured output ---"
cat "$LOG"
echo "[test_fat_subdir] --- end output ---"

fail=0
if grep -F -q "FAT32_MARKER" "$LOG"; then
    echo "[test_fat_subdir] OK: root-level FAT32_MARKER round-trip"
else
    echo "[test_fat_subdir] MISS: root FAT32_MARKER"
    fail=1
fi
if grep -F -q "NESTED_MARKER" "$LOG"; then
    echo "[test_fat_subdir] OK: NESTED_MARKER read through SUBDIR/"
else
    echo "[test_fat_subdir] MISS: NESTED_MARKER (subdir walk failed)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fat_subdir] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_fat_subdir] PASS"
