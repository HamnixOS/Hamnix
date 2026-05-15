#!/usr/bin/env bash
# scripts/test_ext4_sb.sh - M16.51 verification.
#
# Boot with build/ext4.img attached via virtio-blk. The kernel
# probes vda, finds non-FAT, falls through to ext4_init(vda) which
# parses the 1024-byte superblock and prints magic + geometry.
# This test asserts those log lines appear — i.e. the ext4 driver
# successfully read the superblock through the block layer.
#
# Subsequent milestones (group descriptors, inode table, extent
# tree, dir walk) will replace this with a real /cat /ext/HELLO.TXT
# end-to-end test.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_ext4_sb] (1/3) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_sb] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ext4_sb] (3/3) Boot QEMU with ext4 image as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 10s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_sb] --- captured output ---"
sed -n '/block layer smoke test/,/Hamnix: cpus_online/p' "$LOG"
echo "[test_ext4_sb] --- end output ---"

fail=0
for needle in \
    "/dev/vda probed non-FAT" \
    "ext4: mounted; block_size=1024 inodes_count=128" \
    "blocks_per_group=8192 inodes_per_group=128" \
    "first_data_block=1 inode_size=256" \
    "ext4 inode#2 mode=41ed size=1024"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4_sb] OK: '$needle'"
    else
        echo "[test_ext4_sb] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_sb] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ext4_sb] PASS"
