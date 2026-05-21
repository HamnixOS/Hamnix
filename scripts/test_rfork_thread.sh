#!/usr/bin/env bash
# scripts/test_rfork_thread.sh - §1 regression for the native rfork
# RFMEM thread path (SYS_RFORK 256 with RFPROC|RFMEM).
#
# Pipeline mirrors scripts/test_rfork.sh:
#   1. Build all userland binaries (hamsh + coreutils).
#   2. Build the fixture tests/test_rfork_thread.ad to
#      build/user/test_rfork_thread.elf (lands at /bin/test_rfork_thread
#      in the cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the §1 rfork-thread body is
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_rfork_thread` over serial, exit.
#   6. Grep the serial log for the creator + thread banners + PASS.
#
# The fixture calls sys_rfork_thread(RFPROC|RFMEM|RFNOWAIT, stack, 0):
# the new thread runs on its own caller-supplied stack, shares the
# creator's address space, writes a sentinel into a SHARED global, and
# exits; the creator spins on that global and reaches PASS once it sees
# the write. RFNOWAIT means the creator never reaps the thread (it
# self-reaps). PASS = the serial log shows the start banner, the
# thread banner, "shared write observed", and "PASS".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_rfork_thread.elf

echo "[test_rfork_thread] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rfork_thread] (2/5) Build tests/test_rfork_thread.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_rfork_thread.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_rfork_thread] (3/5) Plant /init = hamsh + fixture in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_rfork_thread] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rfork_thread] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "/bin/test_rfork_thread" 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_rfork_thread] --- captured output ---"
cat "$LOG"
echo "[test_rfork_thread] --- end output ---"

fail=0

if grep -F -q "[rfork-thread] start" "$LOG"; then
    echo "[test_rfork_thread] OK: fixture ran"
else
    echo "[test_rfork_thread] MISS: fixture banner missing"
    fail=1
fi

# The new thread actually ran user code on its own stack.
if grep -F -q "[rfthr] hello from thread" "$LOG"; then
    echo "[test_rfork_thread] OK: thread banner present"
else
    echo "[test_rfork_thread] MISS: thread banner absent"
    fail=1
fi

# Cross-thread shared-address-space write was observed by the creator.
if grep -F -q "[rfork-thread] shared write observed" "$LOG"; then
    echo "[test_rfork_thread] OK: address space genuinely shared"
else
    echo "[test_rfork_thread] MISS: shared write never observed"
    fail=1
fi

if grep -F -q "[rfork-thread] PASS" "$LOG"; then
    echo "[test_rfork_thread] OK: creator reached PASS"
else
    echo "[test_rfork_thread] MISS: PASS line absent"
    fail=1
fi

# Negative markers — surface a failure path explicitly.
if grep -F -q "[rfork-thread] FAIL" "$LOG"; then
    echo "[test_rfork_thread] DIAG: fixture reported a FAIL line"
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_rfork_thread] DIAG: kernel CPU trap during the run"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rfork_thread] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rfork_thread] PASS"
