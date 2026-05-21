#!/usr/bin/env bash
# scripts/test_ext4_fsync.sh — M16.x §12.4 verification:
# ext4 fsync + crash/reboot persistence.
#
# Two-part test:
#
#   Part A — fsync smoke. The kernel runs ext4_fsync_smoke_test() at
#   boot: create a file, write a marker, fsync (issue the block-device
#   cache barrier via blk_flush), read it back. Asserts the smoke
#   marker.
#
#   Part B — persistence across a reboot. The strongest proof an
#   fsync is real: boot QEMU once, write a uniquely-marked file into
#   the ext4 volume through the shell `>` redirect (which goes through
#   the ordered, write-through ext4 write path), exit cleanly. Then
#   boot a SECOND QEMU instance against the SAME, now-detached
#   ext4.img and `cat` the file back. If the write reached the disk
#   image, the marker survives the reboot.
#
# The ext4.img is NOT regenerated between the two boots — that is the
# whole point: the second boot must see what the first boot wrote.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

MARKER="FSYNC_PERSIST_$(date +%s)"

echo "[test_ext4_fsync] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_fsync] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_fsync] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# Work on a private copy of ext4.img so a re-run starts clean and the
# repo's build/ext4.img is left pristine.
DISK=$(mktemp --suffix=.ext4-persist.img)
cp build/ext4.img "$DISK"

LOG1=$(mktemp)
LOG2=$(mktemp)
trap 'rm -f "$LOG1" "$LOG2" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ext4_fsync] (4/5) Boot #1 — write $MARKER to /ext, fsync, halt"
set +e
(
    sleep 3
    printf 'echo %s > /ext/PERSIST.TXT\n' "$MARKER"
    sleep 2
    printf 'cat /ext/PERSIST.TXT\n'
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

echo "[test_ext4_fsync] (5/5) Boot #2 — re-attach the SAME disk, read it back"
(
    sleep 3
    printf 'cat /ext/PERSIST.TXT\n'
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

echo "[test_ext4_fsync] --- boot #1 ext4/fsync lines ---"
grep -E 'ext4: fsync|PERSIST' "$LOG1" || true
echo "[test_ext4_fsync] --- boot #2 PERSIST lines ---"
grep -E 'PERSIST' "$LOG2" || true
echo "[test_ext4_fsync] --- end ---"

fail=0

# Part A: fsync smoke marker on the first boot.
if grep -F -q "ext4: fsync smoke PASS" "$LOG1"; then
    echo "[test_ext4_fsync] OK: ext4 fsync smoke (flush + read-back)"
else
    echo "[test_ext4_fsync] MISS: 'ext4: fsync smoke PASS'"
    fail=1
fi

# Boot #1 must echo the marker back (write path works in-session).
if grep -F -q "$MARKER" "$LOG1"; then
    echo "[test_ext4_fsync] OK: boot #1 wrote and read $MARKER"
else
    echo "[test_ext4_fsync] MISS: boot #1 did not read back $MARKER"
    fail=1
fi

# Part B: the marker must survive into the SECOND boot's read.
if grep -F -q "$MARKER" "$LOG2"; then
    echo "[test_ext4_fsync] OK: $MARKER survived the reboot (persistence)"
else
    echo "[test_ext4_fsync] MISS: $MARKER NOT found after reboot"
    echo "[test_ext4_fsync] --- boot #2 full log ---"
    cat "$LOG2"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_fsync] FAIL (qemu rc1=$rc1 rc2=$rc2)"
    exit 1
fi
echo "[test_ext4_fsync] PASS"
