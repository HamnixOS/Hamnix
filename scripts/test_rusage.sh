#!/usr/bin/env bash
# scripts/test_rusage.sh — getrusage(2) CPU-time verification.
#
# Proves the new per-task user/system CPU-tick accounting (kernel/sched/
# core.ad current_task_account_tick, driven from the timer ISR in
# arch/x86/kernel/time.ad) flows through _u_getrusage (linux_abi/
# u_syscalls.ad) into the rusage timevals. The in-kernel rusage_selftest()
# (gated on the cpio marker /etc/rusage-test) lets the timer ISR accrue a
# few system ticks to the boot task, then drives _u_getrusage and asserts
# ru_stime advanced (real CPU-time accounting) and the unsupported tail
# stayed zeroed. The selftest does all the work and needs NO extra QEMU
# disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_rusage] PASS   (kernel prints [RUSAGE] PASS)
# Fail marker:  [test_rusage] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_RUSAGE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_rusage] (1/3) Build userland + plant /etc/rusage-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_RUSAGE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_rusage] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rusage] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_rusage] --- rusage self-test output ---"
grep -a -E "\[RUSAGE\]" "$LOG" || true
echo "[test_rusage] --- end ---"

fail=0

if grep -a -F -q "[RUSAGE] FAIL" "$LOG"; then
    echo "[test_rusage] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[RUSAGE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[RUSAGE] PASS" "$LOG"; then
    echo "[test_rusage] MISS: self-test PASS banner (expected '[RUSAGE] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rusage] --- full log ---"
    cat "$LOG"
    echo "[test_rusage] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rusage] PASS — getrusage reports real per-task CPU time" \
     "(qemu rc=$rc)"
