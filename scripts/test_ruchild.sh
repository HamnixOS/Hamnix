#!/usr/bin/env bash
# scripts/test_ruchild.sh — getrusage(2) RUSAGE_CHILDREN verification.
#
# Proves the `who` arg of getrusage (linux_abi/u_syscalls.ad _u_getrusage)
# branches on RUSAGE_CHILDREN (-1) and reports the per-task CHILD accumulators
# (cutime/cstime CPU ticks + cminflt/cmajflt page-fault counts, rolled up at
# child reap in kernel/sched/core.ad) instead of the calling task's SELF
# counters. The in-kernel ruchild_selftest() (gated on the cpio marker
# /etc/ruchild-test) seeds the boot task's child accumulators with known
# sentinels (cutime=700, cstime=1300, cminflt=33, cmajflt=44), calls
# _u_getrusage with who=RUSAGE_CHILDREN, and asserts they land in
# ru_utime/ru_stime/ru_minflt/ru_majflt. The selftest does all the work and
# needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ruchild] PASS   (kernel prints [RUCHILD] PASS)
# Fail marker:  [test_ruchild] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_RUCHILD_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ruchild] (1/3) Build userland + plant /etc/ruchild-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_RUCHILD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ruchild] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ruchild] (3/3) Boot QEMU (no extra disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ruchild] --- ruchild self-test output ---"
grep -a -E "\[RUCHILD\]" "$LOG" || true
echo "[test_ruchild] --- end ---"

fail=0

if grep -a -F -q "[RUCHILD] FAIL" "$LOG"; then
    echo "[test_ruchild] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[RUCHILD] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[RUCHILD] PASS" "$LOG"; then
    echo "[test_ruchild] MISS: self-test PASS banner (expected '[RUCHILD] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ruchild] --- full log ---"
    cat "$LOG"
    echo "[test_ruchild] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ruchild] PASS — getrusage RUSAGE_CHILDREN reports child accumulators" \
     "(qemu rc=$rc)"
