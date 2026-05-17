#!/usr/bin/env bash
# scripts/test_devtime.sh — M16.95 regression for /dev/time.
#
# Pipeline mirrors test_devcons.sh exactly:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devtime.ad → /bin/test_devtime
#      in the cpio (build_initramfs.py auto-globs build/user/*.elf).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devtime.ad + FD_TIME_MARK arms are
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_devtime` over the serial stdio,
#      grep for an "[test_devtime] ns=<digits>\n" pattern.
#
# PASS = the captured slice contains a non-empty digit run terminated
# by '\n'. We don't pin a specific value — jiffies advance, and the
# test would be flaky if we did.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devtime.elf

echo "[test_devtime] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devtime] (2/5) Build tests/test_devtime.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devtime.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devtime] (3/5) Plant /init = hamsh + /bin/test_devtime in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devtime] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devtime] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devtime\n'
    sleep 2
    printf 'echo POST_TIME_OK\n'
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

echo "[test_devtime] --- captured output ---"
cat "$LOG"
echo "[test_devtime] --- end output ---"

fail=0
if grep -F -q "[test_devtime] start" "$LOG"; then
    echo "[test_devtime] OK: fixture ran"
else
    echo "[test_devtime] MISS: fixture banner missing"
    fail=1
fi

# Match "[test_devtime] ns=<one or more digits>" — devtime_read
# always emits at least "0" + '\n' (and in practice many seconds of
# jiffies have already elapsed by the time hamsh runs us, so a
# multi-digit run is the realistic case).
if grep -E -q "\[test_devtime\] ns=[0-9]+" "$LOG"; then
    echo "[test_devtime] OK: /dev/time read returned digit string"
else
    echo "[test_devtime] MISS: /dev/time ns= line absent or empty"
    fail=1
fi

if grep -F -q "POST_TIME_OK" "$LOG"; then
    echo "[test_devtime] OK: hamsh remains responsive"
else
    echo "[test_devtime] MISS: hamsh died after /dev/time round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devtime] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devtime] PASS"
