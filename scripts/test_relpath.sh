#!/usr/bin/env bash
# scripts/test_relpath.sh - M16.48 verification.
#
# Drives hamsh through:
#
#     cd /mnt
#     ls               (no arg → uses CWD)
#     cat HELLO.TXT    (relative path; kernel resolves to /mnt/HELLO.TXT)
#     exit
#
# Greps the captured serial for HELLO.TXT (from /ls) and the
# FAT32_MARKER (from /cat). The presence of both proves
# resolve_path() at the syscall layer is prepending the calling
# task's CWD to relative paths.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_relpath] (1/5) Regenerate disk image"
python3 scripts/build_diskimg.py

echo "[test_relpath] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_relpath] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_relpath] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_relpath] (5/5) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cd /mnt\n'
    sleep 1
    printf 'ls\n'
    sleep 1
    printf 'cat HELLO.TXT\n'
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

echo "[test_relpath] --- captured output ---"
cat "$LOG"
echo "[test_relpath] --- end output ---"

fail=0
if grep -F -q "HELLO.TXT" "$LOG"; then
    echo "[test_relpath] OK: ls with no arg returned CWD's entries"
else
    echo "[test_relpath] MISS: HELLO.TXT not in ls output"
    fail=1
fi
if grep -F -q "FAT32_MARKER" "$LOG"; then
    echo "[test_relpath] OK: cat HELLO.TXT resolved + read"
else
    echo "[test_relpath] MISS: FAT32_MARKER not produced by relative /cat"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_relpath] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_relpath] PASS"
