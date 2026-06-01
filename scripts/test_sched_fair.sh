#!/usr/bin/env bash
# scripts/test_sched_fair.sh — #151 CFS-lite weighted-fair scheduling +
# SMP user-task load balancing.
#
# Two independent assertions, two QEMU boots:
#
#   PART A — PRIORITY (CPU SHARE), -smp 1
#     hamsh drives /bin/nice_demo, which SYS_SPAWNs two CPU-bound siblings
#     that share the single CPU:
#       /bin/nice_hi  re-nices itself to -20 (heaviest weight)
#       /bin/nice_lo  re-nices itself to +19 (lightest weight)
#     Each runs an identical fixed wall-clock (jiffies) counting loop and
#     prints "[nice] hi iters=N" / "[nice] lo iters=N". Under the
#     weighted-fair scheduler the nice -20 task gets proportionally more
#     CPU, so hi_iters MUST exceed lo_iters by a clear margin. A pure
#     round-robin scheduler would give them ~equal iters and FAIL.
#
#   PART B — SMP LOAD BALANCE, -smp 2
#     The kernel self-test sched_fair_smp_selftest() (gated on
#     /etc/sched-fair) spawns CPU-bound kthreads and reports, per worker,
#     how many times each ran on cpu0 vs cpu1. With two CPUs the AP idle
#     loop work-steals some workers, so dispatches spread across >1 CPU.
#     We assert "[sched_fair] PASS: workers spread across >1 CPU" plus the
#     weight-ordering / vruntime-accrual PASS lines.
#
# Pass marker:  [test_sched_fair] PASS
# Fail marker:  [test_sched_fair] FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_sched_fair] (1/4) Build userland (hamsh + nice_demo/hi/lo)"
bash scripts/build_user.sh >/dev/null

fail=0

# ----------------------------------------------------------------------
# PART A — priority / CPU-share, driven from hamsh on -smp 1
# ----------------------------------------------------------------------
echo "[test_sched_fair] (2/4) PART A: build kernel with hamsh as /init"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_sched_fair] (3/4) PART A: boot QEMU -smp 1 + drive nice_demo"
LOG_A=$(mktemp)
trap 'rm -f "$LOG_A" "${LOG_B:-}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Drive hamsh via the marker-aware driver: it waits for the shell-ready
# banner before sending `nice_demo`, so the command isn't dropped onto a
# 16550 RX FIFO that has no live reader yet. Force -smp 1 (qemu_drive's
# default is -smp 2; QEMU honours the last -smp on the command line, so
# the trailing override from QEMU_EXTRA_ARGS wins). The window is 600
# jiffies (~6 s guest); give TCG generous wall time for both hogs.
QEMU_EXTRA_ARGS="-smp 1" qemu_drive \
    "$LOG_A" "$ELF" "[hamsh] M16.35 shell ready" 150 \
    -- 'nice_demo' 70 'exit' 2
rc_a="$QEMU_DRIVE_RC"

echo "[test_sched_fair] --- PART A output (nice lines) ---"
grep -E "\[nice\]" "$LOG_A" || true
echo "[test_sched_fair] --- end ---"

if [ "$rc_a" -ne 0 ] && [ "$rc_a" -ne 124 ]; then
    echo "[test_sched_fair] FAIL: PART A qemu exited rc=$rc_a" >&2
    fail=1
fi

HI=$(grep -oE '\[nice\] hi iters=[0-9]+' "$LOG_A" | tail -n1 | grep -oE '[0-9]+$' || true)
LO=$(grep -oE '\[nice\] lo iters=[0-9]+' "$LOG_A" | tail -n1 | grep -oE '[0-9]+$' || true)

if [ -z "$HI" ] || [ -z "$LO" ]; then
    echo "[test_sched_fair] FAIL: PART A did not capture both hi/lo iter counts" >&2
    echo "[test_sched_fair]        hi='$HI' lo='$LO'" >&2
    fail=1
else
    echo "[test_sched_fair] PART A: nice -20 iters=$HI   nice +19 iters=$LO"
    # The nice -20 task must get clearly more CPU. We require hi > lo by a
    # comfortable margin (>= 1.5x) so a near-tie (round-robin regression)
    # fails. The Linux weight ratio between nice -20 and +19 is ~88761/15,
    # so on a fair scheduler the gap is large; 1.5x is a conservative floor
    # that tolerates jiffies-granularity windowing noise.
    if [ "$LO" -eq 0 ]; then
        # lo got essentially no CPU — strongly favours hi, definitely a pass.
        echo "[test_sched_fair] PART A PASS: low-priority task got ~0 CPU share"
    elif [ "$(( HI * 2 ))" -ge "$(( LO * 3 ))" ]; then
        echo "[test_sched_fair] PART A PASS: high-priority task got >= 1.5x the CPU"
    else
        echo "[test_sched_fair] FAIL: high-priority share not dominant (hi=$HI lo=$LO)" >&2
        echo "[test_sched_fair]        expected hi >= 1.5*lo — scheduler not honouring nice" >&2
        fail=1
    fi
fi

# ----------------------------------------------------------------------
# PART B — SMP load balance: kernel self-test on -smp 2
# ----------------------------------------------------------------------
echo "[test_sched_fair] (4/4) PART B: build kernel with /etc/sched-fair + boot -smp 2"
INIT_ELF=build/user/init.elf ENABLE_SCHED_FAIR=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG_B=$(mktemp)
set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG_B" 2>&1
rc_b=$?
set -e

echo "[test_sched_fair] --- PART B output (sched_fair lines) ---"
grep -E "\[sched_fair\]" "$LOG_B" || true
echo "[test_sched_fair] --- end ---"

if [ "$rc_b" -ne 0 ] && [ "$rc_b" -ne 124 ]; then
    echo "[test_sched_fair] FAIL: PART B qemu exited rc=$rc_b" >&2
    fail=1
fi

check_b() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG_B"; then
        echo "[test_sched_fair] PART B PASS: $label"
    else
        echo "[test_sched_fair] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check_b "weight strictly decreases with nice" \
        "[sched_fair] PASS: weight strictly decreases with nice"
check_b "heavy task accrues vruntime slower" \
        "[sched_fair] PASS: heavy task accrues vruntime slower"
check_b "workers spread across >1 CPU" \
        "[sched_fair] PASS: workers spread across >1 CPU"

if grep -qF "[sched_fair] FAIL" "$LOG_B"; then
    echo "[test_sched_fair] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sched_fair] FAIL"
    exit 1
fi

echo "[test_sched_fair] PASS — nice weights CPU share AND runnable work spreads across CPUs"
