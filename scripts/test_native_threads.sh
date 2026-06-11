#!/usr/bin/env bash
# scripts/test_native_threads.sh - #443 gate for the native threading
# stack: lib/thread.ad (thread_spawn / thread_join / Mutex / Chan) over
# the new Plan 9-shape semacquire/semrelease syscalls (314/315) and the
# SYS_SETEXITSEM (316) exit-notification, plus the compiler's LOCK
# atomic intrinsics.
#
# Pipeline mirrors scripts/test_rfork_thread.sh:
#   1. Build all userland binaries (hamsh + coreutils).
#   2. Build the fixture tests/test_native_threads.ad to
#      build/user/test_native_threads.elf (lands at
#      /bin/test_native_threads via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image (sems.ad + exit-sem hook compiled in).
#   5. Boot in QEMU, drive `/bin/test_native_threads` over serial.
#   6. Grep the serial log STRICTLY for the markers.
#
# The fixture spawns 4 RFMEM threads that each do 10000 mutex-protected
# increments of one shared counter, joins all 4, and demands the EXACT
# total 40000 — any lost update (broken atomics, broken semaphore
# sleep/wake, fake mutual exclusion) fails the count check. It then
# round-trips 100 values through a bounded-channel echo thread.
#
# PASS = all of:
#   [nthreads] start
#   [nthreads] spawned 4 workers
#   [nthreads] joined all
#   [nthreads] counter=40000          <- exact-count, the load-bearing line
#   [nthreads] chan echo ok
#   [nthreads] PASS
# and no "[nthreads] FAIL" / kernel "TRAP: vector" lines.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_native_threads.elf

echo "[test_native_threads] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_native_threads] (2/5) Build tests/test_native_threads.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_native_threads.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_native_threads] (3/5) Plant /init = hamsh + fixture in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_native_threads] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_native_threads] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# 4 threads x 10000 mutex round-trips is real work under TCG — allow a
# generous in-guest window before "exit". The drive helper itself gates
# on the boot-ready marker, never on fixed boot sleeps.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_native_threads" 45 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_native_threads] --- captured output ---"
cat "$LOG"
echo "[test_native_threads] --- end output ---"

fail=0

if grep -F -q "[nthreads] start" "$LOG"; then
    echo "[test_native_threads] OK: fixture ran"
else
    echo "[test_native_threads] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[nthreads] spawned 4 workers" "$LOG"; then
    echo "[test_native_threads] OK: 4 threads spawned"
else
    echo "[test_native_threads] MISS: spawn line absent"
    fail=1
fi

if grep -F -q "[nthreads] joined all" "$LOG"; then
    echo "[test_native_threads] OK: all threads joined (exit-sem wakeups)"
else
    echo "[test_native_threads] MISS: join line absent"
    fail=1
fi

# THE load-bearing check: the exact shared-counter total. A single lost
# update anywhere in atomics/semaphores/mutex makes this number wrong.
if grep -F -q "[nthreads] counter=40000" "$LOG"; then
    echo "[test_native_threads] OK: exact count 40000 (no lost updates)"
else
    echo "[test_native_threads] MISS: exact counter line absent"
    fail=1
fi

if grep -F -q "[nthreads] chan echo ok" "$LOG"; then
    echo "[test_native_threads] OK: channel echo round-trips"
else
    echo "[test_native_threads] MISS: channel echo line absent"
    fail=1
fi

if grep -F -q "[nthreads] PASS" "$LOG"; then
    echo "[test_native_threads] OK: fixture PASS"
else
    echo "[test_native_threads] MISS: PASS line absent"
    fail=1
fi

# Negative markers — surface a failure path explicitly.
if grep -F -q "[nthreads] FAIL" "$LOG"; then
    echo "[test_native_threads] DIAG: fixture reported a FAIL line"
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_native_threads] DIAG: kernel CPU trap during the run"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_native_threads] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_native_threads] PASS"
