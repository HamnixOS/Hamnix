#!/usr/bin/env bash
# scripts/test_cwd.sh - M16.47 verification.
#
# Drives hamsh through:
#
#     pwd           (expect "/" — default cwd)
#     cd /etc
#     pwd           (expect "/etc" — inherited from hamsh's chdir)
#     exit
#
# Switched from /mnt/SUBDIR to /etc when SYS_CHDIR validation landed
# (chdir now rejects nonexistent paths). /etc is in the cpio
# initramfs — no disk image required.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_cwd] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_cwd] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_cwd] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_cwd] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'pwd\n'
    sleep 1
    printf 'cd /etc\n'
    sleep 1
    printf 'pwd\n'
    sleep 1
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

echo "[test_cwd] --- captured output ---"
cat "$LOG"
echo "[test_cwd] --- end output ---"

fail=0
# Strip "task: pid N exited" lines AND the "[NNNNNN] " kernel printk
# timestamp prefix that fronts every serial line, so the ^/$ / ^/etc$
# anchors below match pwd's bare output.
cleaned=$(sed -E 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g; s/^\[[0-9]+\] //' "$LOG")

# Sanity: pwd before cd prints "/" on its own line.
if echo "$cleaned" | grep -E -q "^/$"; then
    echo "[test_cwd] OK: default cwd '/' printed"
else
    echo "[test_cwd] MISS: default '/' line"
    fail=1
fi
# After cd, pwd should print /etc.
if echo "$cleaned" | grep -E -q "^/etc\$"; then
    echo "[test_cwd] OK: cwd inherited /etc"
else
    echo "[test_cwd] MISS: '/etc' after cd"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cwd] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_cwd] PASS"
