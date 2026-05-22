#!/usr/bin/env bash
# scripts/test_dotdot.sh - M16.49 verification.
#
# Drives hamsh through:
#
#     cd /etc
#     pwd                  → /etc
#     cd ..
#     pwd                  → /
#     cd /etc/./../etc
#     pwd                  → /etc
#     exit
#
# Tests both ".." popping a component and "." being skipped.
# Once SYS_CHDIR validation landed (chdir rejects nonexistent
# paths), all test paths must point at real cpio entries (was
# previously /mnt/SUBDIR + the fictional /a/c).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_dotdot] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_dotdot] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_dotdot] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_dotdot] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cd /etc\n'
    sleep 1
    printf 'pwd\n'
    sleep 1
    printf 'cd ..\n'
    sleep 1
    printf 'pwd\n'
    sleep 1
    printf 'cd /etc/./../etc\n'
    sleep 1
    printf 'pwd\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
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

echo "[test_dotdot] --- captured output ---"
cat "$LOG"
echo "[test_dotdot] --- end output ---"

fail=0
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG")
# Look for each expected path on its own line.
for needle in "/etc" "/"; do
    if echo "$cleaned" | grep -E -q "^$needle\$"; then
        echo "[test_dotdot] OK: '$needle' line present"
    else
        echo "[test_dotdot] MISS: '$needle' not found on its own line"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_dotdot] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_dotdot] PASS"
