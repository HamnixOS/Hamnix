#!/usr/bin/env bash
# scripts/test_procfs.sh - M16.36 verification.
#
# Boots hamsh as /init, drives it through `/ps` + `exit`, and greps
# the captured serial log for:
#
#   1. the /proc/version banner            → procfs renderer ran
#   2. an /proc/uptime "cs" line           → uptime helper formatted
#   3. the hamsh pid + "__init__" comm     → /proc/tasks walked the
#                                            task table and rendered
#                                            the live shell process

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_procfs] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_procfs] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_procfs] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_procfs] (4/4) Boot QEMU and run /ps via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/ps\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_procfs] --- captured output ---"
cat "$LOG"
echo "[test_procfs] --- end output ---"

fail=0
for needle in \
    "Hamnix bare-metal kernel — M16.36" \
    "cs (" \
    "__init__"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_procfs] OK: '$needle'"
    else
        echo "[test_procfs] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_procfs] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_procfs] PASS"
