#!/usr/bin/env bash
# scripts/test_tmpfs.sh - M16.37 verification.
#
# Drives hamsh through:
#
#     echo hello tmpfs world > /tmp/x
#     cat /tmp/x
#     exit
#
# and checks that:
#   - echo's banner is NOT printed to serial (it was redirected)
#   - cat /tmp/x prints "hello tmpfs world" back to serial
#
# That proves: hamsh's `>` parser ran, SYS_SPAWN wired the child's
# fd 1 to a tmpfs entry, echo wrote to it, the entry persisted past
# the child's exit, and cat reopened it for read.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_tmpfs] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_tmpfs] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_tmpfs] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_tmpfs] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo hello tmpfs world > /tmp/x\n'
    sleep 1
    printf 'cat /tmp/x\n'
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

echo "[test_tmpfs] --- captured output ---"
cat "$LOG"
echo "[test_tmpfs] --- end output ---"

fail=0
if grep -F -q "hello tmpfs world" "$LOG"; then
    echo "[test_tmpfs] OK: 'hello tmpfs world' read back via /cat"
else
    echo "[test_tmpfs] MISS: 'hello tmpfs world'"
    fail=1
fi

# Sanity: the literal line should appear EXACTLY ONCE — once /cat
# replays it. If it appears twice, the redirect didn't catch and
# echo also wrote to serial. (Boot logs may contain other "hello"
# words; we anchor on the exact phrase to avoid false positives.)
count=$(grep -F -c "hello tmpfs world" "$LOG" || true)
if [ "$count" != "1" ]; then
    echo "[test_tmpfs] MISS: expected exactly 1 occurrence, got $count"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tmpfs] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_tmpfs] PASS"
