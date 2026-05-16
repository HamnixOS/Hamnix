#!/usr/bin/env bash
# scripts/test_coreutils.sh - M16.57 verification.
#
# Drives hamsh through three pipelines, one per new userland tool:
#
#     cat /mnt/HELLO.TXT | wc       → "1 8 59" (the FAT marker)
#     cat /mnt/HELLO.TXT | head -1  → the marker, exactly one line
#     cat /mnt/HELLO.TXT | grep FAT → the marker, since "FAT" is in it
#
# Also serves as a regression for the task-slot-reap fix that
# landed alongside: without sys_waitpid releasing slots, we'd
# hit NTASKS=4 limit after the second pipeline.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils] (1/5) Regenerate disk image"
python3 scripts/build_diskimg.py

echo "[test_coreutils] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_coreutils] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils] (5/5) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Each pipeline gets 2 s of headroom — plenty for the multi-stage
# spawn / pipe transfer / exit / waitpid sequence even under host
# load. With 1 s waits, the regression-suite-load runs occasionally
# overlapped the next prompt with a still-running tail.
(
    sleep 3
    printf 'cat /mnt/HELLO.TXT | wc\n'
    sleep 2
    printf 'cat /mnt/HELLO.TXT | head -1\n'
    sleep 2
    printf 'cat /mnt/HELLO.TXT | grep FAT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[test_coreutils] --- captured output ---"
cat "$LOG"
echo "[test_coreutils] --- end output ---"

fail=0
# Tests run multiple pipelines back-to-back; serial output can
# interleave with the kernel's exit-log printk. Strip "task: pid
# N exited" lines + collapse newlines so multi-token assertions
# don't depend on exact line breaks.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" | tr '\n' ' ' | tr -s ' ')

# wc output: 1 line, 8 words, 59 bytes (the FAT32_MARKER string).
if echo "$cleaned" | grep -F -q "1 8 59"; then
    echo "[test_coreutils] OK: wc reported 1 8 59"
else
    echo "[test_coreutils] MISS: '1 8 59' not seen"
    fail=1
fi
# head and grep both deliver the FAT marker — expect both
# instances. (Use a substring grep on the cleaned form so an
# interrupted "FA<...>T32_MARKER..." still counts.)
hits=$(echo "$cleaned" | grep -oF "FAT32_MARKER hello from /mnt/HELLO.TXT" | wc -l)
if [ "$hits" -ge 2 ]; then
    echo "[test_coreutils] OK: head + grep each emitted the marker"
else
    echo "[test_coreutils] MISS: marker count $hits < 2"
    fail=1
fi
# Critical: if task slots leaked, we'd see "create_user_task: no free task slot".
if grep -F -q "no free task slot" "$LOG"; then
    echo "[test_coreutils] MISS: task slots leaked across pipelines"
    fail=1
else
    echo "[test_coreutils] OK: task slots reaped across pipelines"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils] PASS"
