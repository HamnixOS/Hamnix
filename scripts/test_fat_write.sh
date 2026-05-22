#!/usr/bin/env bash
# scripts/test_fat_write.sh — M16.x §12.5 verification: FAT32 write
# path (create / extend / overwrite / delete) + reboot persistence.
#
# Two-part test:
#
#   Part A — FAT write smoke. The kernel runs fat_write_smoke_test()
#   at boot: create FATW.TXT, write a 700-byte payload (forces the
#   cluster chain to extend past one 512-byte cluster), read it back,
#   overwrite a mid-file slice, then delete and confirm the file is
#   gone. Asserts the smoke marker.
#
#   Part B — persistence across a reboot. The FAT image is attached
#   as a virtio disk (so it is a real disk, not the memory-baked ram0
#   copy). Boot #1 writes a uniquely-marked file to /mnt through the
#   shell `>` redirect (vfs_open_write -> fat_open_write). Boot #2
#   re-attaches the SAME disk image and cat's the file back — the
#   marker must survive.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

MARKER="FATPERSIST_$(date +%s)"

echo "[test_fat_write] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_fat_write] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_fat_write] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# Private copy of the FAT image so re-runs start clean.
DISK=$(mktemp --suffix=.fat-persist.img)
cp build/disk.img "$DISK"

LOG1=$(mktemp)
LOG2=$(mktemp)
trap 'rm -f "$LOG1" "$LOG2" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_fat_write] (4/5) Boot #1 — write $MARKER to /mnt, halt"
set +e
(
    sleep 3
    printf 'echo %s > /mnt/PERSIST.TXT\n' "$MARKER"
    sleep 2
    printf 'cat /mnt/PERSIST.TXT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG1" 2>&1
rc1=$?

echo "[test_fat_write] (5/5) Boot #2 — re-attach the SAME disk, read back"
(
    sleep 3
    printf 'cat /mnt/PERSIST.TXT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG2" 2>&1
rc2=$?
set -e

echo "[test_fat_write] --- boot #1 fat lines ---"
grep -E 'fat:|PERSIST' "$LOG1" || true
echo "[test_fat_write] --- boot #2 PERSIST lines ---"
grep -E 'PERSIST' "$LOG2" || true
echo "[test_fat_write] --- end ---"

fail=0

# Part A: kernel-side FAT write smoke.
if grep -F -q "fat: write smoke PASS" "$LOG1"; then
    echo "[test_fat_write] OK: fat write smoke (create/extend/overwrite/delete)"
else
    echo "[test_fat_write] MISS: 'fat: write smoke PASS'"
    fail=1
fi

# Boot #1 must echo the marker back (write path works in-session).
if grep -F -q "$MARKER" "$LOG1"; then
    echo "[test_fat_write] OK: boot #1 wrote and read $MARKER"
else
    echo "[test_fat_write] MISS: boot #1 did not read back $MARKER"
    fail=1
fi

# Part B: the marker must survive into the second boot.
if grep -F -q "$MARKER" "$LOG2"; then
    echo "[test_fat_write] OK: $MARKER survived the reboot (persistence)"
else
    echo "[test_fat_write] MISS: $MARKER NOT found after reboot"
    echo "[test_fat_write] --- boot #2 full log ---"
    cat "$LOG2"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fat_write] FAIL (qemu rc1=$rc1 rc2=$rc2)"
    exit 1
fi
echo "[test_fat_write] PASS"
