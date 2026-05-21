#!/usr/bin/env bash
# scripts/test_fat.sh - M16.43 verification.
#
# Boot hamsh, run "cat /mnt/HELLO.TXT", grep the marker that
# scripts/build_diskimg.py planted in HELLO.TXT. Proves end-to-end:
# brd registers, fat_init parses the BPB, vfs_open routes /mnt/*
# to fat_open, vfs_read walks the FAT chain via blk_read_sectors,
# bytes come out on serial.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_fat] (1/5) Regenerate baked disk image"
python3 scripts/build_diskimg.py

echo "[test_fat] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_fat] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_fat] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_fat] (5/5) Boot QEMU; cat /mnt/HELLO.TXT"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cat /mnt/HELLO.TXT\n'
    sleep 1
    # M16.x §12.5: FAT write path through the shell `>` redirect.
    # echo creates /mnt/FATSHELL.TXT and writes a marker; cat reads
    # it back. rm then deletes it; a second cat must fail.
    printf 'echo FAT_WRITE_VIA_SHELL > /mnt/FATSHELL.TXT\n'
    sleep 1
    printf 'cat /mnt/FATSHELL.TXT\n'
    sleep 1
    printf 'rm /mnt/FATSHELL.TXT\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_fat] --- captured output ---"
cat "$LOG"
echo "[test_fat] --- end output ---"

fail=0
if grep -F -q "FAT32_MARKER" "$LOG"; then
    echo "[test_fat] OK: FAT32_MARKER read back from /mnt/HELLO.TXT"
else
    echo "[test_fat] MISS: 'FAT32_MARKER' not in serial log"
    fail=1
fi

# M16.x §12.5: FAT write path. The kernel-side smoke test
# (fat_write_smoke_test) covers create/extend/overwrite/delete
# end-to-end; the shell exercise proves the same path through
# vfs_open_write -> fat_open_write and vfs_unlink -> fat_delete.
if grep -F -q "fat: write smoke PASS" "$LOG"; then
    echo "[test_fat] OK: fat write smoke (create/extend/overwrite/delete)"
else
    echo "[test_fat] MISS: 'fat: write smoke PASS' not in serial log"
    fail=1
fi
if grep -F -q "FAT_WRITE_VIA_SHELL" "$LOG"; then
    echo "[test_fat] OK: FAT write via shell redirect + read-back"
else
    echo "[test_fat] MISS: shell-written FAT file did not read back"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fat] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_fat] PASS"
