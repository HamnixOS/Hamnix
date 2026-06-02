#!/usr/bin/env bash
# scripts/test_procstat_cpu.sh — /proc/<pid>/stat CPU-time verification.
#
# Proves the per-task user/system CPU-tick accounting (kernel/sched/
# core.ad current_task_account_tick, driven from the timer ISR in
# arch/x86/kernel/time.ad) is rendered into /proc/<pid>/stat fields 14
# (utime) and 15 (stime) by _emit_linux_stat (sys/src/9/port/devproc.ad).
# The in-kernel procstat_cpu_selftest() (gated on the cpio marker
# /etc/procstat-cpu-test) lets the timer ISR accrue a few system ticks to
# the boot task, renders _emit_linux_stat for the boot slot, and asserts
# field 15 is the real tick count, not the literal 0. The selftest does
# all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procstat_cpu] PASS   (kernel prints [PROCSTAT_CPU] PASS)
# Fail marker:  [test_procstat_cpu] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCSTAT_CPU_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procstat_cpu] (1/3) Build userland + plant /etc/procstat-cpu-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCSTAT_CPU_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procstat_cpu] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procstat_cpu] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procstat_cpu] --- procstat_cpu self-test output ---"
grep -a -E "\[PROCSTAT_CPU\]" "$LOG" || true
echo "[test_procstat_cpu] --- end ---"

fail=0

if grep -a -F -q "[PROCSTAT_CPU] FAIL" "$LOG"; then
    echo "[test_procstat_cpu] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCSTAT_CPU] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCSTAT_CPU] PASS" "$LOG"; then
    echo "[test_procstat_cpu] MISS: self-test PASS banner (expected '[PROCSTAT_CPU] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procstat_cpu] --- full log ---"
    cat "$LOG"
    echo "[test_procstat_cpu] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procstat_cpu] PASS — /proc/<pid>/stat reports real per-task CPU time" \
     "(qemu rc=$rc)"
