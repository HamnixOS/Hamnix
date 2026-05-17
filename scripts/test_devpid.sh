#!/usr/bin/env bash
# scripts/test_devpid.sh — M16.95 regression for /dev/pid.
#
# Mirrors test_devcons.sh / test_devtime.sh: rebuild user + kernel,
# boot QEMU, run /bin/test_devpid, assert a positive-integer pid + '\n'
# came out.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devpid.elf

echo "[test_devpid] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devpid] (2/5) Build tests/test_devpid.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devpid.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devpid] (3/5) Plant /init = hamsh + /bin/test_devpid in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devpid] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devpid] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devpid\n'
    sleep 2
    printf 'echo POST_PID_OK\n'
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

echo "[test_devpid] --- captured output ---"
cat "$LOG"
echo "[test_devpid] --- end output ---"

fail=0
if grep -F -q "[test_devpid] start" "$LOG"; then
    echo "[test_devpid] OK: fixture ran"
else
    echo "[test_devpid] MISS: fixture banner missing"
    fail=1
fi

# Positive integer pid. The kernel never hands out pid 0 to a user
# task (slot 0 is the idle/boot kthread), so we require [1-9] then any
# trailing digits.
if grep -E -q "\[test_devpid\] pid=[1-9][0-9]*" "$LOG"; then
    echo "[test_devpid] OK: /dev/pid read returned positive integer"
else
    echo "[test_devpid] MISS: /dev/pid line absent or non-positive"
    fail=1
fi

if grep -F -q "POST_PID_OK" "$LOG"; then
    echo "[test_devpid] OK: hamsh remains responsive"
else
    echo "[test_devpid] MISS: hamsh died after /dev/pid round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devpid] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devpid] PASS"
