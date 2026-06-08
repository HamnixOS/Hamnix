#!/usr/bin/env bash
# scripts/test_idle_cpu_burn.sh — host-visible IDLE CPU-burn check.
#
# WHY THIS EXISTS
# ---------------
# The user reported that on real hardware Hamnix tends to overheat, and
# specifically that the box burns CPU once it reaches the shell / on the
# shutdown path. This test gives REGRESSION VISIBILITY for the steady-state
# half of that: once the guest is idle at the hamsh prompt, how much HOST
# CPU does the QEMU process actually consume?
#
# A correctly-idle kernel HLTs (BSP idle loop) and parks idle APs in HLT
# until a reschedule IPI — so the QEMU process should consume only a small
# fraction of one host core. If a future change makes the kernel busy-spin
# at idle (e.g. a poll-yield loop that never halts, or an AP idle loop that
# PAUSE-spins instead of HLTing — the exact class of bug that overheats the
# NUC), the QEMU process pegs near 100% (or N*100% for N vCPUs) and this
# test FAILS, surfacing the regression long before anyone touches metal.
#
# HOW IT MEASURES
# ---------------
# We boot Hamnix to the interactive hamsh loop (the "[hamsh:stage-07]
# loop-enter" marker, same boot recipe as scripts/test_hamsh_heartbeat.sh),
# with NO input piped in so the guest is genuinely idle. Once the prompt is
# up we sample the QEMU process's cumulative CPU time (utime+stime, in clock
# ticks) from /proc/<qemu_pid>/stat at T0 and again at T0+SAMPLE_SECS. The
# busy fraction is:
#
#     busy% = 100 * (cpu_ticks_delta / clk_tck) / SAMPLE_SECS
#
# This is "CPU-seconds consumed per wall-clock second", expressed as a
# percentage of ONE host core. With multiple vCPUs the theoretical ceiling
# is NPROC*100%, but an idle guest should sit far below 100% regardless.
#
# IMPORTANT TCG CAVEAT
# --------------------
# Under QEMU's TCG (pure software emulation — what CI uses, no KVM), the
# guest's MWAIT may NOT truly halt the vCPU the way HLT does: TCG can keep
# translating/executing the idle thread's spin even when the guest intends
# to sleep. So the idle fraction measured here on TCG is an IMPERFECT PROXY
# for real-hardware power draw. The value of this test is therefore:
#   (a) REGRESSION VISIBILITY — catch a future change that makes the idle
#       loop spin much harder than today's baseline; and
#   (b) a NUMBER THE USER CAN EYEBALL on every run.
# Because of the TCG caveat the PASS threshold is deliberately GENEROUS so a
# normal TCG idle passes; it is overridable via the IDLE_CPU_MAX_PCT env var
# for stricter local runs or KVM hosts. The measured busy% is PRINTED on
# BOTH pass and fail so the number is always visible.
#
# ENV KNOBS
#   IDLE_CPU_MAX_PCT   PASS if busy% <= this (default 85). Generous for TCG.
#   SAMPLE_SECS        measurement window in seconds (default 10).
#   IDLE_SMP           number of guest vCPUs (default 2, exercises AP idle).
#   BOOT_TIMEOUT_SECS  max seconds to wait for the prompt (default 90).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

IDLE_CPU_MAX_PCT="${IDLE_CPU_MAX_PCT:-85}"
SAMPLE_SECS="${SAMPLE_SECS:-10}"
IDLE_SMP="${IDLE_SMP:-2}"
BOOT_TIMEOUT_SECS="${BOOT_TIMEOUT_SECS:-90}"

echo "[test_idle_cpu_burn] (1/4) Build"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/idle-cpu-burn.XXXXXX.log)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$LOG"
}
trap cleanup EXIT

echo "[test_idle_cpu_burn] (2/4) Boot QEMU (idle, smp=$IDLE_SMP), wait for prompt"
# No input piped in: a fully idle interactive shell. We background QEMU so
# we can sample the host-side CPU usage of its process while the guest sits
# idle at the prompt. -monitor none + -serial file keeps it headless and
# lets us watch the boot log for the loop-enter marker.
qemu-system-x86_64 \
    -kernel "$ELF" -smp "$IDLE_SMP" -nographic -no-reboot -m 256M \
    -monitor none -serial file:"$LOG" < /dev/null > /dev/null 2>&1 &
QEMU_PID=$!

# Wait for the interactive hamsh loop to come up (or timeout). Poll the log.
deadline=$(( $(date +%s) + BOOT_TIMEOUT_SECS ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_idle_cpu_burn] FAIL: QEMU exited before reaching the prompt"
        echo "[test_idle_cpu_burn] --- boot log tail ---"
        tail -50 "$LOG" | strings || true
        exit 1
    fi
    if grep -F -q "[hamsh:stage-07] loop-enter" "$LOG" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "[test_idle_cpu_burn] FAIL: hamsh never reached the interactive loop" \
         "within ${BOOT_TIMEOUT_SECS}s (stage-07 marker absent)"
    echo "[test_idle_cpu_burn] --- boot log tail ---"
    tail -50 "$LOG" | strings || true
    exit 1
fi
echo "[test_idle_cpu_burn] prompt is up — guest is now idle"

echo "[test_idle_cpu_burn] (3/4) Sample host CPU over ${SAMPLE_SECS}s window"

# Read cumulative CPU time (utime + stime, fields 14 and 15) of the QEMU
# process from /proc/<pid>/stat, in clock ticks. Field 1 is the pid and
# field 2 (comm) may contain spaces inside parentheses, so we strip up to
# and including the final ')' before splitting on whitespace — then utime
# is the 12th remaining field and stime the 13th (kernel proc(5) numbering
# minus the two leading fields we removed).
read_cpu_ticks() {
    local pid="$1" stat rest
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo ""; return; }
    rest="${stat#*) }"
    # shellcheck disable=SC2206
    local f=($rest)
    # f[0]=state ... proc(5): field 14=utime,15=stime -> indices 11,12 here.
    local utime="${f[11]}" stime="${f[12]}"
    echo $(( utime + stime ))
}

CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

t0=$(read_cpu_ticks "$QEMU_PID")
if [ -z "$t0" ]; then
    echo "[test_idle_cpu_burn] FAIL: could not read /proc/$QEMU_PID/stat (T0)"
    exit 1
fi
sleep "$SAMPLE_SECS"
t1=$(read_cpu_ticks "$QEMU_PID")
if [ -z "$t1" ]; then
    echo "[test_idle_cpu_burn] FAIL: could not read /proc/$QEMU_PID/stat (T1)" \
         "(QEMU may have exited mid-sample)"
    exit 1
fi

delta_ticks=$(( t1 - t0 ))
# busy% of one host core = 100 * (delta_ticks/CLK_TCK) / SAMPLE_SECS.
# Compute with integer math scaled by 100 (one decimal not needed): use
# awk only if available for a clean decimal; fall back to integer otherwise.
if command -v awk >/dev/null 2>&1; then
    busy_pct=$(awk -v d="$delta_ticks" -v c="$CLK_TCK" -v s="$SAMPLE_SECS" \
        'BEGIN { printf "%.1f", (d / c) / s * 100.0 }')
else
    busy_pct=$(( delta_ticks * 100 / CLK_TCK / SAMPLE_SECS ))
fi

echo "[test_idle_cpu_burn] (4/4) Result"
echo "[test_idle_cpu_burn]   vcpus=$IDLE_SMP  window=${SAMPLE_SECS}s  clk_tck=$CLK_TCK"
echo "[test_idle_cpu_burn]   qemu cpu-ticks consumed: $delta_ticks"
echo "[test_idle_cpu_burn]   => idle busy = ${busy_pct}% of one host core" \
     "(threshold ${IDLE_CPU_MAX_PCT}%)"

# Integer comparison (strip any decimal). awk gives the authoritative
# decimal; floor it for the threshold test.
busy_int=${busy_pct%.*}
[ -z "$busy_int" ] && busy_int=0

if [ "$busy_int" -le "$IDLE_CPU_MAX_PCT" ]; then
    echo "[test_idle_cpu_burn] PASS: idle busy ${busy_pct}% <= ${IDLE_CPU_MAX_PCT}%" \
         "(guest halts at idle — not busy-spinning)"
    exit 0
else
    echo "[test_idle_cpu_burn] FAIL: idle busy ${busy_pct}% > ${IDLE_CPU_MAX_PCT}%" \
         "— QEMU is pegged, the guest is busy-spinning at idle instead of" \
         "halting. This is the overheat-class regression: check the BSP idle" \
         "loop and the AP idle loop (should HLT/MWAIT, not PAUSE-spin)."
    echo "[test_idle_cpu_burn] --- boot log tail ---"
    tail -30 "$LOG" | strings || true
    exit 1
fi
