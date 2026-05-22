#!/usr/bin/env bash
# scripts/test_cow_fork.sh - copy-on-write fork stress regression.
#
# Drives tests/test_cow_fork.ad, which forks repeatedly (8 iterations)
# and, on every iteration, has the parent and child each write a
# distinct sentinel into a shared .bss array and a stack buffer, then
# verifies each side sees ONLY its own write. This proves the COW fork
# path (vm_cow_share_all + the productive #PF handler) gives a forked
# child a private address space without the old ~33 MiB eager copy.
#
# Pipeline:
#   1. Build all userland binaries (hamsh).
#   2. Build tests/test_cow_fork.ad -> build/user/test_cow_fork.elf
#      (lands at /bin/test_cow_fork in the cpio via build_initramfs.py).
#   3. /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image.
#   5. Boot QEMU, run /bin/test_cow_fork over serial stdio, exit.
#   6. Grep the serial log for the per-iteration + PASS banners.
#
# PASS = the log contains "[cow] PASS" and shows both a "child ok" and
# a "parent ok" line for every iteration, with no "[cow] FAIL" line.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_cow_fork.elf

echo "[test_cow_fork] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_cow_fork] (2/5) Build tests/test_cow_fork.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_cow_fork.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_cow_fork] (3/5) Plant /init = hamsh + /bin/test_cow_fork in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_cow_fork] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_cow_fork] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_cow_fork" 30 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_cow_fork] --- captured output ---"
cat "$LOG"
echo "[test_cow_fork] --- end output ---"

fail=0

if grep -F -q "[cow] start" "$LOG"; then
    echo "[test_cow_fork] OK: fixture ran"
else
    echo "[test_cow_fork] MISS: fixture banner absent"
    fail=1
fi

# Every iteration must show the child observing its own private write
# and the parent's value surviving the child's divergent write.
iters=8
i=0
while [ "$i" -lt "$iters" ]; do
    if grep -F -q "[cow] iter $i child ok" "$LOG"; then
        echo "[test_cow_fork] OK: iter $i child saw private write"
    else
        echo "[test_cow_fork] MISS: iter $i child-ok banner absent"
        fail=1
    fi
    if grep -F -q "[cow] iter $i parent ok" "$LOG"; then
        echo "[test_cow_fork] OK: iter $i parent value preserved"
    else
        echo "[test_cow_fork] MISS: iter $i parent-ok banner absent"
        fail=1
    fi
    i=$((i + 1))
done

# A FAIL line means COW leaked one side's write into the other.
if grep -F -q "[cow] FAIL" "$LOG"; then
    echo "[test_cow_fork] FAIL: fixture reported a COW privacy violation"
    grep -F "[cow] FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "[cow] PASS" "$LOG"; then
    echo "[test_cow_fork] OK: fixture reached PASS"
else
    echo "[test_cow_fork] MISS: PASS banner absent"
    fail=1
fi

# Diagnostics: a COW share OOM or a CPU exception is a hard failure.
if grep -F -q "COW share OOM" "$LOG"; then
    echo "[test_cow_fork] DIAG: kernel logged a COW share OOM (page/refcount leak?)"
    fail=1
fi
# An ACTUAL trap prints "[trap-diag] vec=" — match that, not the
# harmless one-time "[trap-diag] install:" banner every boot emits.
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_cow_fork] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cow_fork] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_cow_fork] PASS -- copy-on-write fork keeps parent/child private"
