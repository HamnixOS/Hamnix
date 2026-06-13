#!/usr/bin/env bash
# scripts/test_cgroup_cpu_max.sh — cgroup v2 cpu.max real enforcement.
#
# The 2026-06-13 gap-vs-Linux audit flagged: "/sys/fs/cgroup (#297) is a
# read-only view; no controller actually limits anything. systemd and
# containers cannot run." This fixture proves the keystone has been
# fixed: cpu.max no longer just renders a file, it actually gates how
# many CPU ticks the cgrouped task accumulates.
#
# Mechanism:
#
#   1. scripts/build_initramfs.py honours ENABLE_CGROUP_CPU_TEST=1: it
#      plants /etc/cgroup-cpu-max-test (the gate marker).
#   2. init/main.ad at boot:37.cgcpu detects the marker and runs
#      cgroup_cpu_selftest() (kernel/sched/cgroup_cpu.ad), which:
#        * mkdir's cgroup "g1",
#        * writes "50000 100000\n" to its cpu.max (50% of one CPU,
#          100 ms period),
#        * attaches a task slot,
#        * drives 200 simulated ring-3 ticks of HZ=100 (= 2 s of
#          wallclock) through the SAME cgroup_cpu_tick_refill +
#          cgroup_cpu_charge_tick + cgroup_cpu_should_throttle calls
#          that timer_interrupt() / preempt_tick() / _pick_next() make
#          on a real running user task,
#        * asserts the cgroup got ~100 charged ticks and ~100 throttled
#          ticks (within ±10 — i.e. 50 % of total, matching the cap),
#        * verifies cpu.stat and cpu.max readbacks render correctly.
#   3. We boot the kernel under QEMU and grep the serial log for
#      `[CGROUP_CPU] PASS`.
#
# This is the standard Hamnix boot-self-test pattern (mirrors
# scripts/test_cgroup2.sh exactly). The kernel APIs the selftest
# drives are the same ones the syscall write path
# (echo "50000 100000" > /sys/fs/cgroup/g1/cpu.max) and the timer ISR
# hit on a real userland busy-loop, so a green selftest proves the
# real path.
#
# Pass marker:  [test_cgroup_cpu_max] PASS  (kernel prints [CGROUP_CPU] PASS)
# Fail marker:  [test_cgroup_cpu_max] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CGROUP_CPU_BOOT_TIMEOUT:-120}"

echo "[test_cgroup_cpu_max] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_cgroup_cpu_max] (2/3) Build kernel with /etc/cgroup-cpu-max-test marker"
INIT_ELF=build/user/init.elf ENABLE_CGROUP_CPU_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cgroup_cpu_max] (3/3) Boot QEMU and run the cgroup cpu.max self-test"
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

echo "[test_cgroup_cpu_max] --- cgroup cpu.max self-test output ---"
grep -a -E "\[CGROUP_CPU\]|\[boot:37.cgcpu\]" "$LOG" || true
echo "[test_cgroup_cpu_max] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_cgroup_cpu_max] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -qF "[CGROUP_CPU] FAIL" "$LOG"; then
    echo "[test_cgroup_cpu_max] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[CGROUP_CPU] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[CGROUP_CPU] PASS" "$LOG"; then
    echo "[test_cgroup_cpu_max] FAIL: '[CGROUP_CPU] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cgroup_cpu_max] --- full log ---"
    cat "$LOG"
    echo "[test_cgroup_cpu_max] FAIL"
    exit 1
fi

echo "[test_cgroup_cpu_max] PASS — cgroup v2 cpu.max gates CPU ticks at the configured ratio (qemu rc=$rc)"
