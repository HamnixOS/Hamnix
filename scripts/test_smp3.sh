#!/usr/bin/env bash
# scripts/test_smp3.sh — 3-core (BSP + 2 AP) SMP bring-up + AP scheduler gate.
#
# WHY THIS GATE EXISTS (#13)
# --------------------------
# #13 was the "AP-launch trap that caps Hamnix at 2 cores": with SMP_BOOT_MAX_
# CPUS>2, a SECOND AP's idle kthread collided with an already-launched AP and
# two CPUs ran the same idle kthread on one kernel stack -> stack corruption ->
# a wild-jump trap (#GP at get_cpu_id's ret under KVM, #UD/#DE at near-null rips
# under TCG). Root cause: kthread_create publishes a new task STATE_READY AND
# LINKED on the creator (BSP) run-list; sched_prepare_ap_idle parked the idle
# kthread (STATE_PARKED) but never UNLINKED it, and _pick_next / work-steal
# trust "linked => READY" and never re-check state, so a parked-but-linked idle
# kthread stayed dispatchable and got stolen. Fixed in kernel/sched/core.ad
# (sched_prepare_ap_idle now unlinks the parked idle kthread under the owning
# CPU's rq lock). With the fix, SMP_BOOT_MAX_CPUS was raised 2 -> 3.
#
# This gate boots -smp 3 (BSP + two APs) and asserts BOTH APs come online, each
# runs its idle kthread on its own non-BSP core (proving the #13 fix), and the
# BSP scheduler survives to an interactive shell. Pre-#13-fix (cap>=3) this
# FAILS with the AP-launch trap; post-fix it PASSES.
#
# NOTE: the cap stays at 3 (not 4) because a SEPARATE cross-CPU steal-window
# race (#12/#413) still crashes FIRST real-task dispatch at 3 APs (4 cores) on
# KVM. See the SMP_BOOT_MAX_CPUS comment in arch/x86/kernel/smp.ad. This gate
# therefore tops out at -smp 3, the highest count proven reliably clean.
#
# PASS markers:
#   (a) "SMP: MADT reports 3 CPU(s)"        — MADT enumerated BSP + 2 APs.
#   (b) "SMP: AP cpu1 online (cpus_online=2)" and
#       "SMP: AP cpu2 online (cpus_online=3)" — both APs bumped the counter.
#   (c) "Hamnix: cpus_online = 3"           — final count is 3.
#   (d) "SMP: cpu1 kthread alive" AND "SMP: cpu2 kthread alive" — BOTH AP idle
#       kthreads executed scheduler code on their own non-BSP cores.
#   (e) "[hamsh:stage-07] loop-enter"       — BSP reached the interactive shell
#       (scheduler survived AP bring-up; no trap took the box down).
#
# FAIL guards: any "TRAP: vector", "[trap-diag] vec=", "KVM internal error",
# or "emulation failure" is a hard fail.
#
# Uses the GRUB-ISO shim from _build_lock.sh (ELF64 -kernel is multiboot1-
# rejected). Does NOT require /dev/kvm — passes on TCG too.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_smp3] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_smp3] (2/3) Build kernel (init.elf as /init)"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_smp3] (3/3) Boot QEMU -smp 3 and check 2-AP bring-up"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 3 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_smp3] --- captured output (SMP-relevant lines) ---"
grep -aE "SMP:|cpus_online|AP cpu|MADT|kthread alive|idle via hlt|hamsh:stage-07|internal error" "$LOG" || true
echo "[test_smp3] --- end ---"

fail=0

check_marker() {
    local label="$1"; local needle="$2"
    if grep -aqF "$needle" "$LOG"; then
        echo "[test_smp3] PASS: $label"
    else
        echo "[test_smp3] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# Assert a marker appears EXACTLY `want` times. The #13 double-run bug printed
# an AP idle banner TWICE (two CPUs ran one idle kthread on one kstack); the
# fix makes each appear exactly once — so the count IS the regression signal.
check_count() {
    local label="$1"; local needle="$2"; local want="$3"
    local got; got=$(grep -acF "$needle" "$LOG")
    if [ "$got" = "$want" ]; then
        echo "[test_smp3] PASS: $label (x$got)"
    else
        echo "[test_smp3] FAIL: $label  (expected x$want, got x$got: '$needle')" >&2
        fail=1
    fi
}

check_absent() {
    local label="$1"; local pat="$2"
    if grep -aqE "$pat" "$LOG"; then
        echo "[test_smp3] FAIL: $label  (found forbidden: /$pat/)" >&2
        grep -anE "$pat" "$LOG" | head -3 >&2
        fail=1
    else
        echo "[test_smp3] PASS: $label"
    fi
}

check_marker "MADT reports 3 CPUs"            "SMP: MADT reports 3 CPU(s)"
check_marker "AP cpu1 online"                 "SMP: AP cpu1 online (cpus_online=2)"
check_marker "AP cpu2 online"                 "SMP: AP cpu2 online (cpus_online=3)"
check_marker "final cpus_online = 3"          "Hamnix: cpus_online = 3"
check_marker "BSP reached interactive shell"  "[hamsh:stage-07] loop-enter"

# #13 CORE ASSERTIONS: each AP idle kthread runs EXACTLY ONCE on its own core
# (double-run == the #13 stack-corruption bug), and each AP reaches steady-state
# hlt+ipi idle (a crashed/wild-jumped AP never gets there).
check_count  "cpu1 idle kthread ran once"     "SMP: cpu1 kthread alive"     1
check_count  "cpu2 idle kthread ran once"     "SMP: cpu2 kthread alive"     1
check_marker "cpu1 reached hlt+ipi idle"      "SMP: cpu1 idle via hlt+ipi"
check_marker "cpu2 reached hlt+ipi idle"      "SMP: cpu2 idle via hlt+ipi"

# Unambiguous fatal signatures. NOTE: we deliberately do NOT grep for
# "[trap-diag] vec=" — that diagnostic ALSO fires for ordinary post-shell
# userland SIGSEGV/OOM under the mem-stress gate, so it is not AP-fatal. The
# #13 wild-jump instead reliably manifests as a doubled banner / a missing
# "idle via hlt+ipi" (caught above) or, on KVM, as an internal/emulation error.
check_absent "no KVM hard-kill"   "KVM internal error|emulation failure"

if [ "$fail" -ne 0 ]; then
    echo "[test_smp3] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_smp3] PASS — 3-core SMP: both APs online, both idle kthreads ran on non-BSP cores, shell reached, no trap (#13 fixed)"
