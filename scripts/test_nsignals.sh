#!/usr/bin/env bash
# scripts/test_nsignals.sh — per-task signal-delivery accounting verification.
#
# Proves the new per-task signal counter (kernel/sched/core.ad nsignals,
# charged from signal_post at the signal-latch site via the slot-indexed
# task_account_signal_at helper) flows through _u_getrusage
# (linux_abi/u_syscalls.ad ru_nsignals 0x78) and the read accessor. The
# in-kernel nsignals_selftest() (gated on the cpio marker /etc/nsignals-test)
# charges 5 delivered signals via the same helper signal_post drives, asserts
# the read accessor rose by exactly 5, then renders the rusage struct and
# asserts 0x78 matches. The selftest does all the work and needs NO extra
# QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_nsignals] PASS   (kernel prints [NSIGNALS] PASS)
# Fail marker:  [test_nsignals] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_NSIGNALS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_nsignals] (1/3) Build userland + plant /etc/nsignals-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_NSIGNALS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_nsignals] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nsignals] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_nsignals] --- nsignals self-test output ---"
grep -a -E "\[NSIGNALS\]" "$LOG" || true
echo "[test_nsignals] --- end ---"

fail=0

if grep -a -F -q "[NSIGNALS] FAIL" "$LOG"; then
    echo "[test_nsignals] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[NSIGNALS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[NSIGNALS] PASS" "$LOG"; then
    echo "[test_nsignals] MISS: self-test PASS banner (expected '[NSIGNALS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nsignals] --- full log ---"
    cat "$LOG"
    echo "[test_nsignals] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_nsignals] PASS — getrusage reports real per-task signal count" \
     "(qemu rc=$rc)"
