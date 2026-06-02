#!/usr/bin/env bash
# scripts/test_pgfault.sh — per-task page-fault accounting verification.
#
# Proves the new per-task page-fault counters (kernel/sched/core.ad minflt /
# majflt, charged from the page-fault handler arch/x86/kernel/trap_diag.ad on
# resolved demand-zero / COW / swap-in faults) flow through _u_getrusage
# (linux_abi/u_syscalls.ad ru_minflt 0x40 / ru_majflt 0x48) and the read
# accessors. The in-kernel pgfault_selftest() (gated on the cpio marker
# /etc/pgfault-test) charges 3 minor + 2 major faults via the same helpers the
# fault handler drives, asserts the read accessors rose by exactly 3 / 2, then
# renders the rusage struct and asserts 0x40 / 0x48 match. The selftest does
# all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_pgfault] PASS   (kernel prints [PGFAULT] PASS)
# Fail marker:  [test_pgfault] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PGFAULT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pgfault] (1/3) Build userland + plant /etc/pgfault-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PGFAULT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_pgfault] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_pgfault] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_pgfault] --- pgfault self-test output ---"
grep -a -E "\[PGFAULT\]" "$LOG" || true
echo "[test_pgfault] --- end ---"

fail=0

if grep -a -F -q "[PGFAULT] FAIL" "$LOG"; then
    echo "[test_pgfault] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PGFAULT] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PGFAULT] PASS" "$LOG"; then
    echo "[test_pgfault] MISS: self-test PASS banner (expected '[PGFAULT] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pgfault] --- full log ---"
    cat "$LOG"
    echo "[test_pgfault] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_pgfault] PASS — getrusage/procstat report real per-task page faults" \
     "(qemu rc=$rc)"
