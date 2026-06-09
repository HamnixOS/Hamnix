#!/usr/bin/env bash
# scripts/test_sched_affinity.sh — sched_setaffinity(2)/sched_getaffinity(2)/
# membarrier(2) Linux-ABI verification.
#
# Proves these are REAL, scheduler-honored implementations — not stubs:
#
#   * sched_setaffinity / sched_getaffinity store a per-task CPU-affinity
#     bitmask (cpu_affinity in the task struct, kernel/sched/core.ad) and the
#     per-CPU-runqueue scheduler HONORS it:
#       - a single-CPU mask round-trips through set/get,
#       - placement (sched_pick_target_cpu), work-steal
#         (_sched_try_pull_locked) and the deferred migration of a preempted
#         task only ever land a task on a CPU whose bit is set,
#       - a setaffinity that excludes the CPU a READY task currently sits on
#         re-homes (migrates) that task to an allowed CPU.
#     On an SMP boot the in-kernel selftest asserts a CPU1-pinned task is
#     enqueued on CPU1's runqueue (asserted via the rq_cpu field, since the
#     selftest controls the scheduler internals). If only one CPU comes
#     online it asserts the single-CPU-mask round-trip, the only-CPU pin
#     no-op-success, and the migration-marking logic on the data structures.
#
#   * membarrier(2): QUERY returns a nonzero supported-command bitmask that
#     includes the commands the handler implements (GLOBAL / GLOBAL_EXPEDITED
#     / PRIVATE_EXPEDITED + the REGISTER_* no-ops); GLOBAL / PRIVATE_EXPEDITED
#     issue a REAL system-wide memory barrier (a local mfence plus an
#     all-but-self IPI that forces every other online CPU through a
#     serialising interrupt entry — smp_membarrier_broadcast in
#     arch/x86/kernel/apic.ad) and return 0.
#
# The in-kernel sched_affinity_membarrier_selftest() (linux_abi/u_syscalls.ad)
# is gated on the cpio marker /etc/sched-affinity-test and drives the real
# affinity store/enforcement + the real _u_membarrier dispatch — the exact
# path a Debian/glibc binary takes. Everything is in-RAM (task_table + LAPIC),
# so — like test_statx_getrandom.sh — this needs NO disk image.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim. Booted with
# -smp 2 so the SMP CPU1-pinning assertion exercises; the selftest degrades
# to the single-CPU assertions automatically if only the BSP comes online.
#
# Pass marker:  [test_sched_affinity] PASS   (kernel prints [SCHED_AFFINITY] PASS)
# Fail marker:  [test_sched_affinity] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_SCHED_AFFINITY_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_sched_affinity] (1/3) Build userland + plant /etc/sched-affinity-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_SCHED_AFFINITY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_sched_affinity] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_sched_affinity] (3/3) Boot QEMU -smp 2 (no disk image — pure tmpfs)"
set +e
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_sched_affinity] --- self-test output ---"
grep -a -E "\[SCHED_AFFINITY\]|\[affinity\]|\[membarrier\]" "$LOG" || true
echo "[test_sched_affinity] --- end ---"

fail=0

if grep -a -F -q "[SCHED_AFFINITY] FAIL" "$LOG"; then
    echo "[test_sched_affinity] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[SCHED_AFFINITY] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[SCHED_AFFINITY] PASS" "$LOG"; then
    echo "[test_sched_affinity] MISS: self-test PASS banner (expected '[SCHED_AFFINITY] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sched_affinity] --- full log ---"
    cat "$LOG"
    echo "[test_sched_affinity] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_sched_affinity] PASS — sched_setaffinity/getaffinity enforcement +" \
     "membarrier work through Linux-ABI dispatch (qemu rc=$rc)"
