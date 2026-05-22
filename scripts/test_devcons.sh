#!/usr/bin/env bash
# scripts/test_devcons.sh — M16.94 regression for the first
# Plan 9-style device file: /dev/cons as a real VFS path.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_devcons live there).
#   2. Build the test fixture tests/test_devcons.ad to
#      build/user/test_devcons.elf (lands at /bin/test_devcons in
#      the cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new FD_CONS_MARK plumbing +
#      sys/src/9/port/devcons.ad body are compiled in.
#   5. Boot in QEMU, drive `/bin/test_devcons` over the serial stdio,
#      then run `echo POST_CONS_OK` to assert hamsh remains
#      responsive (a regression where opening /dev/cons hijacks the
#      global console would kill the shell here).
#   6. Grep the serial log for the marker.
#
# The test fixture opens /dev/cons with OWRITE, writes
# "M16.94 cons test\n", and closes. The kernel side fans that write
# out through early_putc() to UART + VGA/fb + printk so the marker
# appears on the serial log. PASS = both the marker AND the
# POST_CONS_OK sentinel appear in the captured output.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devcons.elf

echo "[test_devcons] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devcons] (2/5) Build tests/test_devcons.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devcons.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devcons] (3/5) Plant /init = hamsh + /bin/test_devcons in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devcons] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devcons] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Same pacing as test_errstr.sh — let the kernel finish its
    # smoke tests before hamsh starts SYS_READ'ing stdin.
    sleep 3
    printf '/bin/test_devcons\n'
    sleep 2
    # Responsiveness check. If FD_CONS_MARK accidentally hijacked
    # the console (e.g. by stealing the UART RX FIFO or wedging
    # early_putc), this echo wouldn't make it back through hamsh's
    # readline + write to stdout.
    printf 'echo POST_CONS_OK\n'
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

echo "[test_devcons] --- captured output ---"
cat "$LOG"
echo "[test_devcons] --- end output ---"

fail=0
# Banner first — proves the fixture ran end to end.
if grep -F -q "[test_devcons] start" "$LOG"; then
    echo "[test_devcons] OK: fixture ran"
else
    echo "[test_devcons] MISS: fixture banner missing"
    fail=1
fi

# The /dev/cons round-trip itself.
if grep -F -q "M16.94 cons test" "$LOG"; then
    echo "[test_devcons] OK: /dev/cons write reached serial"
else
    echo "[test_devcons] MISS: /dev/cons marker absent"
    fail=1
fi

# Hamsh responsiveness after the test exits. If this is missing,
# opening /dev/cons broke the global console.
if grep -F -q "POST_CONS_OK" "$LOG"; then
    echo "[test_devcons] OK: hamsh remains responsive"
else
    echo "[test_devcons] MISS: hamsh died after /dev/cons round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devcons] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devcons] PASS"
