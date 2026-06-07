#!/usr/bin/env bash
# scripts/test_smp_user.sh — STAGE A per-CPU TSS proof: a USER task runs
# on a NON-BSP CPU (cpu1).
#
# This is the headline assertion for the per-CPU TSS work: before it, user
# tasks were pinned to the BSP because an AP had no loaded TR/TSS, so a
# ring3->ring0 transition (IRQ/syscall from a user task) on an AP had no
# RSP0 to load and would fault — _pick_next deliberately skipped all user
# tasks on APs. With per-CPU TSS (one TSS + TSS descriptor + IST1 #DF stack
# per logical CPU, each AP ltr'ing its own during bring-up) the AP can run
# CPL3 work.
#
# The kernel self-test smp_user_ap_selftest() (gated on /etc/smp-user)
# spawns a tiny CPL3 user task (smp_user_probe_entry: busy-loop + SYS_WRITE
# + SYS_EXIT), fences it onto the AP, and reports how many times it was
# dispatched on cpu1. The SYS_WRITE/SYS_EXIT are the load-bearing step: the
# SYSCALL from ring3 on the AP reads the AP's OWN per_cpu_tss RSP0. A
# missing/shared TSS would fault here.
#
# PASS markers (all must be present):
#   (a) "[smp_user] starting Stage-A per-CPU-TSS USER-on-AP self-test"
#   (b) "[smp_user] PASS: USER task ran on a non-BSP CPU (cpu1) via per-CPU TSS"
#   (c) "[smp_user] ring3 task ran a syscall on its CPU"   (the user banner —
#       proves the ring3->ring0 syscall transition completed on the AP)
#   (d) No "TRAP: vector" (no #DF/#GP/#PF from the AP user dispatch).
#   (e) No "PANIC".
#
# This test does NOT require /dev/kvm (passes on TCG).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[smp_user] (1/3) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[smp_user] (2/3) Build kernel with /etc/smp-user marker"
# Keep hamsh's normal /init so the post-test boot continues as usual; the
# self-test fires during the kernel boot sequence before start_first_task.
ENABLE_SMP_USER=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-smp-user.XXXXXX.log)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[smp_user] (3/3) Boot QEMU -smp 2 and run user-on-AP self-test (120s timeout)"
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

echo "[smp_user] --- captured output (relevant lines) ---"
grep -a -E "\[smp_user\]|SMP:|cpus_online|TRAP:|PANIC|panic:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' \
    || true
echo "[smp_user] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -qF "$needle" "$LOG"; then
        echo "[smp_user] PASS: $label"
    else
        echo "[smp_user] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# (a) Self-test ran.
check_marker "self-test triggered by /etc/smp-user" \
    "[smp_user] starting Stage-A per-CPU-TSS USER-on-AP self-test"

# (b) The headline assertion: a user task ran on cpu1.
check_marker "USER task ran on non-BSP CPU (cpu1)" \
    "[smp_user] PASS: USER task ran on a non-BSP CPU (cpu1) via per-CPU TSS"

# (c) The user task's own syscall banner printed (ring3->ring0 on the AP).
check_marker "ring3 syscall completed on the AP" \
    "[smp_user] ring3 task ran a syscall on its CPU"

# (d) No CPU exception traps.
if grep -a -qE "TRAP: vector" "$LOG"; then
    echo "[smp_user] FAIL: CPU exception (TRAP: vector) during user-on-AP run" >&2
    grep -a -E "TRAP: vector" "$LOG" | head -5 >&2
    fail=1
else
    echo "[smp_user] PASS: no CPU exception traps"
fi

# (e) No kernel panics.
if grep -a -qE "PANIC|panic:|BUG:" "$LOG"; then
    echo "[smp_user] FAIL: kernel panic during user-on-AP run" >&2
    grep -a -E "PANIC|panic:|BUG:" "$LOG" | head -5 >&2
    fail=1
else
    echo "[smp_user] PASS: no kernel panics"
fi

if grep -a -qF "[smp_user] FAIL:" "$LOG"; then
    echo "[smp_user] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -E "\[smp_user\] FAIL:" "$LOG" | head -5 >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[smp_user] FAIL (qemu rc=$rc)"
    echo "[smp_user] --- last 40 log lines ---"
    tail -40 "$LOG" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' >&2
    exit 1
fi

echo "[smp_user] PASS — a CPL3 USER task was dispatched and ran on cpu1 via its own per-CPU TSS"
