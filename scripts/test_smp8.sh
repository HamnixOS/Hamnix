#!/usr/bin/env bash
# scripts/test_smp8.sh — 8-core (BSP + 7 AP) SMP bring-up + AP scheduler gate.
#
# WHY THIS GATE EXISTS (#12 / #413)
# ---------------------------------
# #12/#413 was the "cross-CPU steal-window race that capped Hamnix at 3 cores".
# After #13 (parked-idle-kthread unlink) and #55 (AP preemption tick) landed,
# -smp 3 was reliably clean but -smp 4+ crashed during the FIRST real-task
# dispatch onto a 3rd AP: a kernel #GP/#UD with a corrupted rip made of the
# low-RAM BIOS-fill pattern (0xf000ff53.../0xf000d43d...) — a `ret` off an
# uninitialised low stack — or a stack-protector canary smash inside
# _sched_try_pull_locked. Two complementary AP-idle-loop bugs (both in
# kernel/sched/core.ad) were the cause:
#
#   (1) UNPINNED AP IDLE KTHREAD — the per-CPU idle (swapper) kthread was
#       created AFFINITY_ALL, so after the idle loop switched away from it (to a
#       real task) it sat STATE_READY + linked + on_cpu==0 and another CPU's
#       work-steal PULLED this AP's private idle kthread onto itself, running it
#       with a stale captured my_cpu_id → cross-CPU state corruption. FIX: pin
#       each AP idle kthread to (1<<cpu_id) in sched_prepare_ap_idle.
#
#   (2) IF=1 DISPATCH WINDOW — the AP idle loop (unlike schedule(), which is
#       entered from an ISR at IF=0) ran its dispatch tail with IRQs enabled, so
#       a timer tick / reschedule IPI landing after `current_idx_pcpu=nxt` but
#       before __switch_to_asm re-entered schedule() and saved the IDLE stack
#       pointer into nxt->sp → two contexts on one kstack. FIX: disable IRQs at
#       the top of the idle loop so the dispatch-and-switch runs at IF=0.
#
# With both fixes, SMP_BOOT_MAX_CPUS was raised 3 -> 8 (the highest count proven
# reliably clean to an interactive shell on BOTH KVM and TCG).
#
# This gate boots -smp 8 (BSP + seven APs) and asserts ALL seven APs come
# online, each runs its idle kthread EXACTLY ONCE on its own non-BSP core, the
# BSP reaches an interactive shell, the box stays alive (>=1 heartbeat tick),
# and NO trap fires. Pre-fix (cap<8, or cap>=4 without the fix) this FAILS —
# either cpus_online never reaches 8, or the AP-dispatch corruption trips a
# trap. Post-fix it PASSES.
#
# PASS markers:
#   (a) "SMP: MADT reports 8 CPU(s)"            — MADT enumerated BSP + 7 APs.
#   (b) "SMP: AP cpuN online (cpus_online=N+1)" for N=1..7 — each AP counted.
#   (c) "Hamnix: cpus_online = 8"               — final count is 8.
#   (d) "SMP: cpuN kthread alive" x1 for N=1..7 — each AP idle kthread ran once
#       on its own non-BSP core (a doubled banner == the two-CPUs-on-one-kstack
#       corruption class).
#   (e) "[hamsh:stage-07] loop-enter"           — BSP reached the shell.
#   (f) "[hamsh-alive] tick="                    — box stayed alive past the shell.
#
# FAIL guards: any "trap-diag] vec=", "KVM internal error", "emulation failure",
# "SWITCH-BAD-SP", "AP-DISPATCH-BAD-SP", "stack-smash", or a BIOS-fill wild rip
# (rip=0xf000...) is a hard fail.
#
# Uses the GRUB-ISO shim from _build_lock.sh (ELF64 -kernel is multiboot1-
# rejected). Does NOT require /dev/kvm — passes on TCG too (slower; hence the
# longer timeout below).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_smp8] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_smp8] (2/3) Build kernel (init.elf as /init)"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_smp8] (3/3) Boot QEMU -smp 8 and check 7-AP bring-up"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# -smp 8 on TCG (CI has no /dev/kvm) brings up 7 APs and multiplexes them onto
# the host cores, so the boot is slower than the -smp 3 gate; give it a
# generous window. The gate still terminates as soon as the heartbeat markers
# appear (the box keeps ticking until the timeout — rc=124 is expected/benign).
set +e
timeout 300s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 8 \
    -nographic \
    -no-reboot \
    -m 2G \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_smp8] --- captured output (SMP-relevant lines) ---"
grep -aE "SMP:|cpus_online|AP cpu|MADT|kthread alive|idle via hlt|hamsh:stage-07|hamsh-alive|internal error" "$LOG" | tail -40 || true
echo "[test_smp8] --- end ---"

fail=0

check_marker() {
    local label="$1"; local needle="$2"
    if grep -aqF "$needle" "$LOG"; then
        echo "[test_smp8] PASS: $label"
    else
        echo "[test_smp8] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

check_count() {
    local label="$1"; local needle="$2"; local want="$3"
    local got; got=$(grep -acF "$needle" "$LOG")
    if [ "$got" = "$want" ]; then
        echo "[test_smp8] PASS: $label (x$got)"
    else
        echo "[test_smp8] FAIL: $label  (expected x$want, got x$got: '$needle')" >&2
        fail=1
    fi
}

check_absent() {
    local label="$1"; local pat="$2"
    if grep -aqE "$pat" "$LOG"; then
        echo "[test_smp8] FAIL: $label  (found forbidden: /$pat/)" >&2
        grep -anE "$pat" "$LOG" | head -3 >&2
        fail=1
    else
        echo "[test_smp8] PASS: $label"
    fi
}

check_marker "MADT reports 8 CPUs"            "SMP: MADT reports 8 CPU(s)"

# Each AP must bump the online counter and run its idle kthread exactly once.
n=1
while [ "$n" -le 7 ]; do
    check_marker "AP cpu$n online"            "SMP: AP cpu$n online (cpus_online=$((n+1)))"
    check_count  "cpu$n idle kthread ran once" "SMP: cpu$n kthread alive"  1
    n=$((n+1))
done

check_marker "final cpus_online = 8"          "Hamnix: cpus_online = 8"
check_marker "BSP reached interactive shell"  "[hamsh:stage-07] loop-enter"
check_marker "box stayed alive (heartbeat)"   "[hamsh-alive] tick="

# Unambiguous fatal signatures for the #12/#413 AP-dispatch corruption.
check_absent "no trap-diag"       "trap-diag\] vec="
check_absent "no KVM hard-kill"   "KVM internal error|emulation failure"
check_absent "no bad-sp dispatch" "SWITCH-BAD-SP|AP-DISPATCH-BAD-SP"
check_absent "no kstack smash"    "stack-smash|KSTACK OVERFLOW"
check_absent "no BIOS-fill wild rip" "rip=0xf000"

if [ "$fail" -ne 0 ]; then
    echo "[test_smp8] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_smp8] PASS — 8-core SMP: all 7 APs online, each idle kthread ran once on its own core, shell reached + heartbeat, no trap (#12/#413 fixed)"
