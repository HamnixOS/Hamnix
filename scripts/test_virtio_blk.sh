#!/usr/bin/env bash
# scripts/test_virtio_blk.sh - M16.44 verification.
#
# Same shape as test_fat.sh but attaches the disk image as a virtio-
# blk PCI device via QEMU's -drive,if=virtio. With the device
# attached, block_smoke_test prefers /dev/vda over /dev/ram0, so
# the FAT read path exercises the full pipeline: PCI probe →
# legacy-virtio init → virtq descriptor chain → kick → used-ring
# completion → FAT chain walk → file bytes to serial.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_virtio_blk] (1/5) Regenerate disk image"
python3 scripts/build_diskimg.py

echo "[test_virtio_blk] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_virtio_blk] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_virtio_blk] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_virtio_blk] (5/5) Boot QEMU with virtio-blk attached"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cat /mnt/HELLO.TXT\n'
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

echo "[test_virtio_blk] --- captured output ---"
cat "$LOG"
echo "[test_virtio_blk] --- end output ---"

fail=0
if grep -F -q "/dev/vda probed FAT" "$LOG"; then
    echo "[test_virtio_blk] OK: virtio-blk vda detected as FAT"
else
    echo "[test_virtio_blk] MISS: '/dev/vda probed FAT' not in log"
    fail=1
fi
if grep -F -q "FAT32_MARKER" "$LOG"; then
    echo "[test_virtio_blk] OK: FAT read through virtio-blk delivered marker"
else
    echo "[test_virtio_blk] MISS: 'FAT32_MARKER' not in log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_virtio_blk] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_virtio_blk] PASS"
