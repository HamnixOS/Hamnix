#!/usr/bin/env bash
# scripts/test_ls.sh - M16.46 verification.
#
# Drives hamsh through:
#
#     ls /mnt
#     ls /mnt/SUBDIR
#     exit
#
# Expects HELLO.TXT, SUBDIR, and NESTED.TXT to appear in the right
# directories. Validates the FAT directory walker + SYS_LISTDIR end
# to end against the baked disk image's two directories.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ls] (1/5) Regenerate disk image"
python3 scripts/build_diskimg.py

echo "[test_ls] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ls] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ls] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ls] (5/5) Boot QEMU and run /ls"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'ls /mnt\n'
    sleep 1
    printf 'ls /mnt/SUBDIR\n'
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

echo "[test_ls] --- captured output ---"
cat "$LOG"
echo "[test_ls] --- end output ---"

fail=0
for needle in "HELLO.TXT" "SUBDIR" "NESTED.TXT"; do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ls] OK: '$needle' listed"
    else
        echo "[test_ls] MISS: '$needle' not in ls output"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_ls] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ls] PASS"
