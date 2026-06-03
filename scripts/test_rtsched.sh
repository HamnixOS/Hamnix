#!/usr/bin/env bash
# scripts/test_rtsched.sh — SCHED_FIFO / SCHED_RR realtime scheduling-policy
# verification.
#
# Proves the realtime scheduling MECHANISM in kernel/sched/core.ad: every task
# carries a scheduling policy (SCHED_OTHER / SCHED_FIFO / SCHED_RR) and, for the
# realtime policies, a realtime priority in [1,99]. The pick-next logic prefers
# any runnable realtime task over all SCHED_OTHER tasks; among realtime tasks
# the highest priority wins; SCHED_RR rotates equal-priority peers on a
# timeslice. The Linux ABI (sched_setscheduler / sched_getscheduler /
# sched_setparam / sched_getparam / sched_get_priority_max / _min) forwards to
# this same mechanism, and the native Plan 9 surface is the `policy <fifo|rr|
# other> <prio>` verb on /proc/<pid>/ctl.
#
# The in-kernel rtsched_selftest() (gated on the cpio marker /etc/rtsched-test)
# drives the REAL sched_set_scheduler / _pick_next / RR-rotation code over
# fabricated fixtures in spare task slots — no real context switch needed — and
# asserts:
#   * sched_get_priority_max/min == 99/1 for FIFO/RR and 0/0 for OTHER
#   * a SCHED_FIFO task at priority 50 is always picked over a runnable
#     SCHED_OTHER task while both are runnable
#   * two SCHED_RR tasks at equal priority alternate on timeslice rotation
#   * a FIFO task is NOT preempted by a newly-runnable lower-priority RR task
# It restores the fixtures to FREE afterward and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_rtsched] PASS   (kernel prints [rtsched] PASS)
# Fail marker:  [test_rtsched] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_RTSCHED_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_rtsched] (1/3) Build userland + plant /etc/rtsched-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_RTSCHED_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_rtsched] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rtsched] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_rtsched] --- rtsched self-test output ---"
grep -a -E "\[rtsched\]" "$LOG" || true
echo "[test_rtsched] --- end ---"

fail=0

if grep -a -F -q "[rtsched] FAIL" "$LOG"; then
    echo "[test_rtsched] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[rtsched] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[rtsched] PASS" "$LOG"; then
    echo "[test_rtsched] MISS: self-test PASS banner (expected '[rtsched] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rtsched] --- full log ---"
    cat "$LOG"
    echo "[test_rtsched] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rtsched] PASS — SCHED_FIFO/SCHED_RR realtime policies verified" \
     "(FIFO>OTHER, RR rotation, FIFO not preempted by lower RR, prio 99/1)" \
     "(qemu rc=$rc)"
