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

# #109: the AP-idle-loop dispatch corruption was an INTERMITTENT race (~1/4 of
# -smp 8 boots pre-fix). A single clean boot proves nothing at that frequency,
# so this gate boots -smp 8 REPEATEDLY (SMP8_REPEAT, default 3) and requires
# EVERY iteration to pass — the race cannot hide behind one lucky boot. Bump
# SMP8_REPEAT (e.g. to 10) for a heavier soak.
REPEAT="${SMP8_REPEAT:-3}"
echo "[test_smp8] (3/3) Boot QEMU -smp 8 x${REPEAT} and check 7-AP bring-up"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

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

iter=1
while [ "$iter" -le "$REPEAT" ]; do
    echo "[test_smp8] ==== boot $iter / $REPEAT ===="
    # -smp 8 on TCG (CI has no /dev/kvm) brings up 7 APs and multiplexes them
    # onto the host cores, so the boot is slower than the -smp 3 gate; give it a
    # generous window. The gate terminates as soon as the heartbeat markers
    # appear (the box keeps ticking until the timeout — rc=124 is expected).
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

    echo "[test_smp8] --- boot $iter captured output (SMP-relevant lines) ---"
    grep -aE "SMP:|cpus_online|AP cpu|MADT|kthread alive|idle via hlt|hamsh:stage-07|hamsh-alive|internal error" "$LOG" | tail -40 || true
    echo "[test_smp8] --- end boot $iter (qemu rc=$rc) ---"

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

    # #109: the BSP idle/swapper is slot 0; an AP that transiently drove the
    # WRONG per-CPU state (stolen idle kthread / two-contexts-on-one-stack)
    # printed a bogus "cpu0 kthread alive" banner (cpu 0 is the BSP and never
    # runs sched_ap_idle_loop) — so ANY cpu0 idle banner is a hard fail.
    check_absent "no bogus cpu0 idle banner" "SMP: cpu0 kthread alive"

    # Unambiguous fatal signatures for the #12/#413/#109 AP-dispatch corruption.
    check_absent "no trap-diag"       "trap-diag\] vec="
    check_absent "no KVM hard-kill"   "KVM internal error|emulation failure"
    check_absent "no bad-sp dispatch" "SWITCH-BAD-SP|AP-DISPATCH-BAD-SP"
    check_absent "no kstack smash"    "stack-smash|KSTACK OVERFLOW"
    check_absent "no BIOS-fill wild rip" "rip=0xf000"

    if [ "$fail" -ne 0 ]; then
        echo "[test_smp8] FAIL on boot $iter / $REPEAT (qemu rc=$rc)"
        exit 1
    fi
    iter=$((iter + 1))
done

echo "[test_smp8] PASS — 8-core SMP x${REPEAT}: all 7 APs online each boot, each idle kthread ran once on its own core, shell reached + heartbeat, no trap (#12/#413/#109 fixed)"

# ---------------------------------------------------------------------------
# HIGH-COUNT (>8) BRING-UP ASSERTION (#109 cap lift 8 -> 64).
#
# With #109 fixed, SMP_BOOT_MAX_CPUS was restored to MAX_CPUS (64), so the OS
# now brings up min(enumerated, 64) cores instead of capping at 8. Assert a
# high-count boot actually reaches an interactive shell with EVERY core online
# and no AP-dispatch corruption. This needs a host with enough logical CPUs +
# hardware virt (a 12-core -smp 12 boot under pure TCG is far too slow for CI),
# so it runs ONLY when /dev/kvm exists and nproc >= HIGH_SMP; otherwise it is
# SKIPPED (not failed) — the 8-core loop above is the CI-portable gate.
HIGH_SMP="${HIGH_SMP:-12}"
if [ -w /dev/kvm ] && [ "$(nproc)" -ge "$HIGH_SMP" ]; then
    echo "[test_smp8] ==== high-count boot: -smp ${HIGH_SMP} (KVM) ===="
    set +e
    timeout 120s qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -kernel "$ELF" \
        -smp "$HIGH_SMP" \
        -nographic -no-reboot -m 2G -monitor none -serial stdio \
        </dev/null > "$LOG" 2>&1
    hrc=$?
    set -e
    echo "[test_smp8] --- high-count captured (SMP lines) ---"
    grep -aE "SMP:|cpus_online|AP cpu|MADT|kthread alive|hamsh:stage-07|hamsh-alive" "$LOG" | tail -30 || true
    echo "[test_smp8] --- end (qemu rc=$hrc) ---"
    hfail=0
    if grep -aqF "Hamnix: cpus_online = ${HIGH_SMP}" "$LOG"; then
        echo "[test_smp8] PASS: high-count cpus_online = ${HIGH_SMP}"
    else
        echo "[test_smp8] FAIL: high-count cpus_online != ${HIGH_SMP}" >&2; hfail=1
    fi
    # Every AP (cpu 1 .. HIGH_SMP-1) must run its idle kthread exactly once, and
    # cpu 0 must NEVER print an idle banner (the #109 corruption tell).
    ap=1
    while [ "$ap" -le $((HIGH_SMP - 1)) ]; do
        got=$(grep -acF "SMP: cpu$ap kthread alive" "$LOG")
        if [ "$got" != "1" ]; then
            echo "[test_smp8] FAIL: high-count cpu$ap idle banner x$got (want x1)" >&2; hfail=1
        fi
        ap=$((ap + 1))
    done
    if grep -aqF "SMP: cpu0 kthread alive" "$LOG"; then
        echo "[test_smp8] FAIL: high-count bogus cpu0 idle banner" >&2; hfail=1
    fi
    for pat in "trap-diag\] vec=" "SWITCH-BAD-SP|AP-DISPATCH-BAD-SP" "stack-smash|KSTACK OVERFLOW" "rip=0xf000" "KVM internal error|emulation failure"; do
        if grep -aqE "$pat" "$LOG"; then
            echo "[test_smp8] FAIL: high-count forbidden signature /$pat/" >&2
            grep -anE "$pat" "$LOG" | head -3 >&2; hfail=1
        fi
    done
    if ! grep -aqF "[hamsh:stage-07] loop-enter" "$LOG"; then
        echo "[test_smp8] FAIL: high-count BSP did not reach shell" >&2; hfail=1
    fi
    if [ "$hfail" -ne 0 ]; then
        echo "[test_smp8] FAIL — high-count -smp ${HIGH_SMP} bring-up (qemu rc=$hrc)"
        exit 1
    fi
    echo "[test_smp8] PASS — high-count -smp ${HIGH_SMP}: all $((HIGH_SMP - 1)) APs online, each idle kthread once, shell reached, no trap (#109 cap lift verified)"
else
    echo "[test_smp8] SKIP high-count boot (need /dev/kvm + nproc >= ${HIGH_SMP}; have nproc=$(nproc), kvm=$( [ -w /dev/kvm ] && echo yes || echo no ))"
fi
