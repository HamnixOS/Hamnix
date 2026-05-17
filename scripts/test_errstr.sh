#!/usr/bin/env bash
# scripts/test_errstr.sh - Phase B / M16.93 regression for SYS_ERRSTR
# (Plan 9-shape error reporting, syscall number 265).
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_errstr live there).
#   2. Build the test fixture tests/test_errstr.ad to
#      build/user/test_errstr.elf (lands at /bin/test_errstr in the
#      cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new SYS_ERRSTR (265) +
#      Phase B stubs are compiled in.
#   5. Boot in QEMU, drive `/bin/test_errstr` over the serial stdio,
#      then `exit`.
#   6. Grep the serial log for the recovered error string.
#
# The test fixture opens /nonexistent/path (forcing a SYS_OPEN ->
# -ENOENT failure with set_current_errstr("file does not exist")),
# then SYS_ERRSTR's the message back into a 128-byte buffer and
# writes it to stdout. PASS = the serial log contains the canonical
# "[test_errstr] got: file does not exist" line.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_errstr.elf

echo "[test_errstr] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_errstr] (2/5) Build tests/test_errstr.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_errstr.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_errstr] (3/5) Plant /init = hamsh + /bin/test_errstr in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_errstr] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_errstr] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Let the kernel finish its smoke tests before hamsh starts
    # SYS_READ'ing stdin. Same pacing as scripts/test_hamsh.sh —
    # the 16550 RX FIFO is 16 bytes and there's no software buffer
    # so we hand-feed each line.
    sleep 3
    printf '/bin/test_errstr\n'
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

echo "[test_errstr] --- captured output ---"
cat "$LOG"
echo "[test_errstr] --- end output ---"

fail=0
# Banner first — proves the binary ran end to end.
if grep -F -q "[test_errstr] start" "$LOG"; then
    echo "[test_errstr] OK: fixture ran"
else
    echo "[test_errstr] MISS: fixture banner missing"
    fail=1
fi

# The actual SYS_ERRSTR round-trip. The error string is installed
# from arch/x86/kernel/syscall.ad's SYS_OPEN failure branch; the
# fixture reads it back and prints "[test_errstr] got: <string>".
if grep -F -q "[test_errstr] got: file does not exist" "$LOG"; then
    echo "[test_errstr] OK: SYS_ERRSTR returned the installed error"
else
    echo "[test_errstr] MISS: error string not echoed correctly"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_errstr] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_errstr] PASS"
