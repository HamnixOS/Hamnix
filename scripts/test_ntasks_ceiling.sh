#!/usr/bin/env bash
# scripts/test_ntasks_ceiling.sh — NTASKS-ceiling concurrency proof.
#
# PURPOSE
#
#   Prove the scheduler task-cap lift NTASKS 64 -> 256 (kernel/sched/core.ad)
#   ACTUALLY took effect — i.e. the kernel can hold MORE than the old 64-task
#   ceiling LIVE SIMULTANEOUSLY in distinct task_table slots, not merely
#   recycle a small slot pool sequentially (which the spawn-loop / spawn-stress
#   tests already cover).
#
#   The in-kernel proof (ntasks_ceiling_test_run, gated on the /etc/ntasks-test
#   cpio marker) runs on the BSP boot task BEFORE start_first_task():
#     1. Creates NTASKS_TEST_HOLD (200) kthreads in a tight loop with IRQs
#        DISABLED and no schedule() between creates, so none of them run yet —
#        each kthread_create publishes its slot as STATE_READY but the
#        cooperative BSP never dispatches it during the burst. They pile up as
#        concurrently-LIVE slots.
#     2. Counts the non-FREE task_table slots at the peak (the simultaneous
#        live high-water mark) and asserts it EXCEEDS the old 64 ceiling.
#     3. Marks each detached and cooperatively schedule()s until all have
#        self-reaped to STATE_FREE, leaving a clean table for the handoff.
#
# PASS markers (all must be present):
#   (a) "[ntasks_test] starting NTASKS-ceiling concurrency proof"
#       The proof was triggered by the /etc/ntasks-test marker.
#   (b) "[ntasks_test] PASS: held N > 64 live tasks at once"  (N > 64)
#       The kernel held more than the OLD ceiling concurrently.
#   (c) "[ntasks_test] DONE"
#       The kthreads all drained cleanly (no slot leak, no drain timeout).
#   (d) No "TRAP: vector", "PANIC", "panic:", "BUG:" in output.
#
# This test does NOT require /dev/kvm.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[ntasks_test] (1/3) Build userland + initramfs with /etc/ntasks-test marker"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

ENABLE_NTASKS_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[ntasks_test] (2/3) Build kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-ntasks-ceiling.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[ntasks_test] (3/3) Boot QEMU -smp 2 and run the ceiling proof (180s timeout)"

set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[ntasks_test] --- captured output (proof-relevant lines) ---"
grep -a -E "\[ntasks_test\]|TRAP:|PANIC|panic:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' \
    || true
echo "[ntasks_test] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -qF "$needle" "$LOG"; then
        echo "[ntasks_test] PASS: $label"
    else
        echo "[ntasks_test] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# (a) Proof triggered.
check_marker "proof triggered by /etc/ntasks-test" \
    "[ntasks_test] starting NTASKS-ceiling concurrency proof"

# (b) Held > 64 live tasks concurrently — extract N and re-assert > 64.
PASS_LINE=$(grep -a -oE "\[ntasks_test\] PASS: held [0-9]+ > 64 live tasks at once" "$LOG" | head -1 || true)
if [ -n "$PASS_LINE" ]; then
    N=$(echo "$PASS_LINE" | grep -oE "held [0-9]+" | grep -oE "[0-9]+")
    if [ "${N:-0}" -gt 64 ]; then
        echo "[ntasks_test] PASS: held ${N} live tasks simultaneously (> old 64 ceiling)"
    else
        echo "[ntasks_test] FAIL: reported live count ${N} is not > 64" >&2
        fail=1
    fi
else
    echo "[ntasks_test] FAIL: ceiling-proof PASS line absent (did not exceed 64 live)" >&2
    fail=1
fi

# (c) Drained cleanly.
check_marker "kthreads drained cleanly (no leak / no timeout)" \
    "[ntasks_test] DONE"

if grep -a -qF "[ntasks_test] FAIL" "$LOG"; then
    echo "[ntasks_test] FAIL: kernel reported an in-test FAIL" >&2
    grep -a -F "[ntasks_test] FAIL" "$LOG" | head -5 >&2
    fail=1
fi

# (d) No traps / panics.
if grep -a -qE "TRAP: vector" "$LOG"; then
    echo "[ntasks_test] FAIL: CPU exception (TRAP: vector) during proof" >&2
    grep -a -E "TRAP: vector" "$LOG" | head -5 >&2
    fail=1
else
    echo "[ntasks_test] PASS: no CPU exception traps"
fi
if grep -a -qE "PANIC|panic:|BUG:" "$LOG"; then
    echo "[ntasks_test] FAIL: kernel panic during proof" >&2
    grep -a -E "PANIC|panic:|BUG:" "$LOG" | head -5 >&2
    fail=1
else
    echo "[ntasks_test] PASS: no kernel panics"
fi

if [ "$fail" -ne 0 ]; then
    echo "[ntasks_test] FAIL (qemu rc=$rc)"
    echo "[ntasks_test] --- last 40 log lines ---"
    tail -40 "$LOG" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' >&2
    exit 1
fi

echo "[ntasks_test] PASS — NTASKS=256 ceiling proven: held > 64 live tasks at once, drained clean"
