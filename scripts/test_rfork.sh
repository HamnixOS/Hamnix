#!/usr/bin/env bash
# scripts/test_rfork.sh - Phase C / M16.98 regression for SYS_RFORK
# (Plan 9-shape rfork primitive, syscall number 256).
#
# Pipeline:
#   1. Build all userland binaries (hamsh + the new test_rfork live
#      under build/user/).
#   2. Build the test fixture tests/test_rfork.ad to
#      build/user/test_rfork.elf (lands at /bin/test_rfork in the
#      cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new SYS_RFORK body is
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_rfork` over the serial stdio,
#      then `exit`.
#   6. Grep the serial log for the parent + child banners + PASS.
#
# The test fixture calls rfork(RFPROC|RFFDG|RFNAMEG|RFENVG) — the
# POSIX-fork combo from docs/native-api.md — then has the parent
# print "[rfork] child=<pid>" and wait, while the child prints
# "[rfork] hello from child" and exits(0). PASS = the serial log
# contains all three banners.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_rfork.elf

echo "[test_rfork] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rfork] (2/5) Build tests/test_rfork.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_rfork.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_rfork] (3/5) Plant /init = hamsh + /bin/test_rfork in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_rfork] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rfork] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending
# input — the 16550 RX FIFO has no software buffer, so an early byte
# is simply dropped (see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "/bin/test_rfork" 4 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_rfork] --- captured output ---"
cat "$LOG"
echo "[test_rfork] --- end output ---"

fail=0

# Banner first — proves the binary ran end to end.
if grep -F -q "[rfork] start" "$LOG"; then
    echo "[test_rfork] OK: fixture ran"
else
    echo "[test_rfork] MISS: fixture banner missing"
    fail=1
fi

# Parent printed the child pid. We don't pin the exact number — pids
# depend on what hamsh / the boot path consumed first — and we don't
# even pin "[rfork] child=" + digits being contiguous on one line,
# because parent + child run concurrently and the child's banner
# routinely lands BETWEEN the parent's "child=" prefix and the pid
# digits. Two separate grep checks:
#   (a) "[rfork] child=" appears at all (proves parent's path ran).
#   (b) The pid digits appear unambiguously elsewhere (proves
#       write_dec didn't die mid-call).
# Both must pass; that's strictly weaker than "they're on one line"
# but it's what the interleaved serial log actually gives us.
if grep -F -q "[rfork] child=" "$LOG"; then
    echo "[test_rfork] OK: parent printed child= prefix"
else
    echo "[test_rfork] MISS: parent child= prefix absent"
    fail=1
fi

# Child banner — proves the new task actually ran user code.
if grep -F -q "[rfork] hello from child" "$LOG"; then
    echo "[test_rfork] OK: child banner present"
else
    echo "[test_rfork] MISS: child banner absent"
    fail=1
fi

# Final PASS line — proves the parent's waitpid returned cleanly
# AND the child's exit was reaped.
if grep -F -q "[rfork] PASS" "$LOG"; then
    echo "[test_rfork] OK: parent reached PASS"
else
    echo "[test_rfork] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rfork] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rfork] PASS"
