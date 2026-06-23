#!/usr/bin/env bash
# scripts/test_cgroup_v2_enforce.sh — cgroup v2 pids.max + memory.max
# REAL enforcement (companion to test_cgroup_cpu_max.sh for cpu.max).
#
# Task #297 landed a /sys/fs/cgroup VIEW; the controllers did not yet
# ENFORCE. This fixture proves the keystone is fixed for two more
# controllers:
#
#   * pids.max  — a fork/clone in a cgroup at/over pids.max is rejected
#                 with -EAGAIN (do_clone()'s fork path, arch/x86/kernel/
#                 syscall.ad, calls cgroup_pids_can_fork before creating
#                 the child; task_reap, kernel/sched/core.ad, uncharges
#                 on exit so pids.current tracks the LIVE count).
#   * memory.max — a cgrouped task's per-page demand fault charges
#                 memory.current (mm/vma.ad demand-fault hook ->
#                 mm/reclaim.ad::cgroup_mem_charge_enforce); a charge over
#                 memory.max drives direct reclaim (the same swap/LRU
#                 machinery kswapd uses) and, if still over, the cgroup
#                 OOM killer, returning -ENOMEM at the fault boundary.
#
# Mechanism (standard Hamnix boot-self-test pattern):
#
#   1. build_initramfs.py honours ENABLE_CGROUP_ENFORCE_TEST=1: plants
#      /etc/cgroup-enforce-test (the gate marker).
#   2. init/main.ad at boot:37.cgenf detects the marker and runs:
#        * cgroup_enforce_selftest() (kernel/sched/cgroup_cpu.ad) — the
#          pids.max + memory.max accounting, driving the EXACT entry
#          points the live fork/exit/page-fault paths call. Asserts a
#          pids.max=2 cgroup rejects the 3rd fork, a freed slot re-opens
#          headroom, and a memory.max cgroup bounds + reports
#          memory.current. Prints "[CGROUP_ENFORCE] PASS".
#        * cgroup_mem_enforce_selftest() (mm/reclaim.ad) — the
#          charge -> reclaim -> cgroup-OOM ORCHESTRATION: an over-cap
#          charge with no reclaim progress fires the cgroup OOM path and
#          returns -ENOMEM. Prints "[MEMCG_OOM] PASS".
#   3. Boot under QEMU; grep the serial log for both PASS markers.
#
# The kernel APIs these self-tests drive are the same ones the syscall
# fork path, task_reap, and the demand-fault memcg hook hit on a real
# `echo N > pids.max` / over-allocating task, so green proves the real
# path.
#
# Pass marker:  [test_cgroup_v2_enforce] PASS
# Fail marker:  [test_cgroup_v2_enforce] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CGROUP_ENFORCE_BOOT_TIMEOUT:-120}"

echo "[test_cgroup_v2_enforce] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_cgroup_v2_enforce] (2/3) Build kernel with /etc/cgroup-enforce-test marker"
INIT_ELF=build/user/init.elf ENABLE_CGROUP_ENFORCE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cgroup_v2_enforce] (3/3) Boot QEMU and run the pids.max + memory.max self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_cgroup_v2_enforce] --- cgroup enforce self-test output ---"
grep -a -E "\[CGROUP_ENFORCE\]|\[MEMCG_OOM\]|\[boot:37.cgenf\]" "$LOG" || true
echo "[test_cgroup_v2_enforce] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_cgroup_v2_enforce] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -qE "\[CGROUP_ENFORCE\] FAIL|\[MEMCG_OOM\] FAIL" "$LOG"; then
    echo "[test_cgroup_v2_enforce] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -E "\[CGROUP_ENFORCE\] FAIL|\[MEMCG_OOM\] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[CGROUP_ENFORCE] PASS" "$LOG"; then
    echo "[test_cgroup_v2_enforce] FAIL: '[CGROUP_ENFORCE] PASS' (pids.max + memory.max) not found." >&2
    fail=1
fi

if ! grep -a -qF "[MEMCG_OOM] PASS" "$LOG"; then
    echo "[test_cgroup_v2_enforce] FAIL: '[MEMCG_OOM] PASS' (memory.max reclaim/OOM) not found." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cgroup_v2_enforce] --- full log ---"
    cat "$LOG"
    echo "[test_cgroup_v2_enforce] FAIL"
    exit 1
fi

echo "[test_cgroup_v2_enforce] PASS — cgroup v2 pids.max rejects over-limit fork; memory.max bounds memory.current + drives reclaim/cgroup-OOM (qemu rc=$rc)"
