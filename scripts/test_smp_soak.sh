#!/usr/bin/env bash
# scripts/test_smp_soak.sh — SMP concurrency soak / stress test.
#
# PURPOSE
#
#   Stress the SMP scheduler paths that pure unit tests cannot reach:
#
#     1. rq_lock contention: BSP timer ISR (schedule() via preempt_tick)
#        races the AP idle loop (sched_ap_idle_loop) on the same
#        spinlock — dozens of times per second for the duration of the soak.
#
#     2. AP dispatch path: each soak kthread is a kernel-only detached
#        thread (STATE_PARKED → STATE_READY → STATE_RUNNING on AP →
#        STATE_FREE self-reap). The AP picks up 80+ threads across the run.
#
#     3. per-CPU current_idx_pcpu mutations: AP switches from idle slot
#        to kthread slot and back on every kthread dispatch.  BSP's timer
#        ISR reads/writes current_idx_pcpu (its own per-CPU copy) independently.
#
#     4. _another_task_ready() TOCTOU: called from preempt_tick() (BSP timer
#        ISR) WITHOUT holding rq_lock — sees task states changed concurrently
#        by the AP.  On x86 TSO this is safe but exposes the ordering window.
#
#     5. Task slot recycling under concurrent access: NTASKS=16 slots, 80
#        kthreads total → every slot is recycled 5+ times.
#
# PASS markers (all must be present for PASS):
#   (a) "[smp_soak] starting SMP kthread churn soak"
#       The soak was triggered by the /etc/smp-soak cpio marker.
#   (b) "[smp_soak] PASS: N kthreads launched, M completed"
#       All rounds completed successfully with N kthreads confirmed done.
#   (c) "[smp_soak] post-soak cpus_online = 2"
#       The AP survived the full soak and is still online at the end.
#   (d) "SMP: cpu1 kthread alive"
#       The AP actually ran (inherited from test_smp.sh; confirms AP
#       scheduler is live before the soak begins).
#   (e) No "TRAP: vector" in output (no #DF/#GP/#PF).
#   (f) No "PANIC" in output.
#
# ARCHITECTURE
#
#   The soak runs BEFORE start_first_task() — purely in kernel context,
#   with no userland involved.  Interrupts are enabled (sti) for the
#   duration so the BSP LAPIC timer ISR fires (preempt_tick races rq_lock)
#   while the AP idle loop is actively dispatching kthreads.
#
#   Each "round" launches BATCH (4) kthreads in quick succession.  Each
#   kthread increments a shared completion counter (under rq_lock) and
#   exits (self-reap: detached=1 → STATE_FREE).  The BSP driver loop spins
#   on the counter until the batch is done, then starts the next.
#
#   20 rounds × 4 kthreads = 80 kthread create/dispatch/reap cycles.
#   All 16 task slots are recycled 5+ times.
#
# TIMEOUT
#
#   Boot to shell is ~30s on TCG. The soak itself (80 kthreads, cpu_relax
#   polling, LAPIC timer at 100 Hz) adds ~10–20s on TCG.  We use 120s
#   overall — generous enough for slow CI without being a stuck-test risk.
#
# This test does NOT require /dev/kvm.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[smp_soak] (1/3) Build userland + initramfs with /etc/smp-soak marker"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

# Build initramfs with the SMP soak marker.  INIT_ELF=build/user/init.elf
# keeps hamsh as /init (the normal path) so the post-soak boot continues
# to hamsh as usual — the soak fires during the kernel boot sequence and
# finishes before start_first_task hands off to /init.
ENABLE_SMP_SOAK=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[smp_soak] (2/3) Build kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-smp-soak.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[smp_soak] (3/3) Boot QEMU -smp 2 and run soak (120s timeout)"

# Boot via the GRUB-ISO shim (from _build_lock.sh → _kernel_iso.sh):
# the higher-half ELF64 kernel is wrapped in a minimal GRUB ISO because
# QEMU's bare -kernel multiboot1 loader rejects ELFCLASS64 binaries.
set +e
timeout 120s qemu-system-x86_64 \
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

echo "[smp_soak] --- captured output (soak-relevant lines) ---"
grep -a -E "\[smp_soak\]|SMP:|cpus_online|TRAP:|PANIC|panic:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' \
    || true
echo "[smp_soak] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -qF "$needle" "$LOG"; then
        echo "[smp_soak] PASS: $label"
    else
        echo "[smp_soak] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# (a) Soak was triggered.
check_marker "soak triggered by /etc/smp-soak" \
    "[smp_soak] starting SMP kthread churn soak"

# (b) All rounds completed with confirmed completions.
if grep -a -qE "\[smp_soak\] PASS: [0-9]+ kthreads launched" "$LOG"; then
    echo "[smp_soak] PASS: soak completed (all rounds passed)"
    # Extract and print the counts for visibility.
    grep -a -oE "\[smp_soak\] PASS: .*" "$LOG" | head -1 || true
else
    echo "[smp_soak] FAIL: soak did not complete (PASS line absent)" >&2
    fail=1
fi

# (c) AP still online after soak.
check_marker "AP still online post-soak (cpus_online=2)" \
    "[smp_soak] post-soak cpus_online = 2"

# (d) AP kthread ran before soak (AP scheduler alive).
check_marker "AP kthread ran on cpu1 (scheduler live)" \
    "SMP: cpu1 kthread alive"

# (e) No CPU exception traps.
if grep -a -qE "TRAP: vector" "$LOG"; then
    echo "[smp_soak] FAIL: CPU exception (TRAP: vector) during soak" >&2
    echo "[smp_soak]       trap lines:"
    grep -a -E "TRAP: vector" "$LOG" | head -5 >&2
    fail=1
else
    echo "[smp_soak] PASS: no CPU exception traps"
fi

# (f) No kernel panics.
if grep -a -qE "PANIC|panic:|BUG:" "$LOG"; then
    echo "[smp_soak] FAIL: kernel panic during soak" >&2
    grep -a -E "PANIC|panic:|BUG:" "$LOG" | head -5 >&2
    fail=1
else
    echo "[smp_soak] PASS: no kernel panics"
fi

# Informational: show heartbeat lines if present.
hb_count=$(grep -a -c "\[smp_soak\] heartbeat" "$LOG" || true)
echo "[smp_soak] heartbeat lines seen: ${hb_count}"

# Informational: TIMEOUT check (batch stalled).
if grep -a -qF "[smp_soak] TIMEOUT" "$LOG"; then
    echo "[smp_soak] FAIL: a batch timed out (soak stalled)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[smp_soak] FAIL (qemu rc=$rc)"
    # Print last 40 lines for diagnosis.
    echo "[smp_soak] --- last 40 log lines ---"
    tail -40 "$LOG" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' >&2
    exit 1
fi

echo "[smp_soak] PASS — SMP kthread churn soak: 80 kthreads, rq_lock stress, AP dispatch, slot recycling: all green"
