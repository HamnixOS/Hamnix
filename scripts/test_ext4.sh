#!/usr/bin/env bash
# scripts/test_ext4.sh - M16.51..M16.54 verification.
#
# Boots the kernel with build/ext4.img attached via virtio-blk so
# vda is detected as ext4 (FAT magic absent at sector 0). The
# ext4 driver mounts at /ext via the standard probe path. The
# test drives hamsh through `/cat /ext/HELLO.TXT` and asserts:
#
#   1. The superblock log lines appeared (M16.51).
#   2. ext4_read_inode produced inode 2 with mode 0x41ED (M16.52).
#   3. The boot-time dirent dump found HELLO.TXT (M16.53).
#   4. /cat /ext/HELLO.TXT delivered the marker — meaning the full
#      read path (root lookup → inode → extent → block → VFS →
#      user) works (M16.54).

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ext4] (5/5) Boot QEMU with ext4 image as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/cat /ext/HELLO.TXT\n'
    sleep 1
    printf '/ls /ext/SUB\n'
    sleep 1
    printf '/cat /ext/SUB/NESTED.TXT\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 18s qemu-system-x86_64 \
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

echo "[test_ext4] --- captured output ---"
cat "$LOG"
echo "[test_ext4] --- end output ---"

fail=0
for needle in \
    "ext4: mounted; block_size=1024 inodes_count=128" \
    "ext4 inode#2 mode=41ed size=1024" \
    "dirent inode=12 name='HELLO.TXT'" \
    "EXT4_MARKER hello from /ext/HELLO.TXT" \
    "NESTED.TXT" \
    "EXT4_NESTED_MARKER /ext/SUB/NESTED.TXT"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4] OK: '$needle'"
    else
        echo "[test_ext4] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ext4] PASS"
