#!/usr/bin/env bash
# scripts/test_pf_smp_race.sh — task #112 regression gate.
#
# Reproduces (and guards against) the intermittent `-smp 2` USER page-fault
# coredump: `[pf] user fault on unmapped va=0x... -> SIGSEGV` (code=139), a
# page-fault CORRECTNESS gap in which a not-present user access whose page a
# SIBLING CPU is resolving in the SAME address space is misclassified as a
# genuine unmapped access and the process is SIGSEGV'd — distinct from the
# fixed `-smp 2` scheduler wedges (#21/#55/#10).
#
# The kernel self-test pf_smp_race_selftest() (gated on /etc/pf-smp-race)
# creates TWO ring-3 tasks that SHARE ONE address space (one PML4 + one VMA
# tree — a CLONE_VM pair) and sweep the SAME large demand-zero anon region,
# one task per CPU, so both CPUs demand-fault the SAME not-present page in
# the same interrupt-latency window. do_page_fault's SMP spurious-not-
# present guard re-reads the LIVE leaf PTE and cleanly re-runs the loser
# instead of falsely SIGSEGV'ing it.
#
# PASS markers (all must hold):
#   (a) "[pf_race] starting SMP cross-CPU demand-fault race self-test"
#   (b) "[pf_race] PASS: both probes swept the shared demand region and reaped"
#   (c) NO "[pf] user fault on unmapped"  (the #112 false SIGSEGV signature)
#   (d) NO "TRAP: vector"  (no #DF/#GP/#PF halt)
#   (e) NO "PANIC"
#
# NOTE: the SMP guard's own hit count is printed as
#   "[pf_race] SMP spurious not-present faults recovered: N"
# N is timing-dependent (the collision window is narrow under TCG) — a run
# with N==0 is still a PASS as long as (c) holds. N>0 is positive proof the
# cross-CPU race fired and was absorbed. This test does NOT need /dev/kvm.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[pf_race] (1/3) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[pf_race] (2/3) Build kernel with /etc/pf-smp-race marker"
ENABLE_PF_SMP_RACE=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-pf-smp-race.XXXXXX.log)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[pf_race] (3/3) Boot QEMU -smp 2 and run the demand-fault race (120s timeout)"
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

echo "[pf_race] --- captured output (relevant lines) ---"
grep -a -E "\[pf_race\]|\[pf\] user fault on unmapped|\[pf\] SPURIOUS|TRAP:|PANIC|panic:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' \
    || true
echo "[pf_race] --- end ---"

fail=0

check_marker() {
    local label="$1"; local needle="$2"
    if grep -a -qF "$needle" "$LOG"; then
        echo "[pf_race] PASS: $label"
    else
        echo "[pf_race] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# (a) self-test ran.
check_marker "self-test triggered by /etc/pf-smp-race" \
    "[pf_race] starting SMP cross-CPU demand-fault race self-test"

# (b) both probes completed their sweep (no hang, no lost task).
check_marker "both probes swept the shared region and reaped" \
    "[pf_race] PASS: both probes swept the shared demand region and reaped"

# (c) THE #112 SIGNATURE: a false user SIGSEGV on the demand region.
if grep -a -qF "[pf] user fault on unmapped" "$LOG"; then
    echo "[pf_race] FAIL: #112 reproduced — false user SIGSEGV on a shared demand page" >&2
    grep -a -E "\[pf\] user fault on unmapped|\[pf\]   cpu=|\[nxdiag\]" "$LOG" | head -12 >&2
    fail=1
else
    echo "[pf_race] PASS: no false 'user fault on unmapped' SIGSEGV"
fi

# (d) no CPU exception halt.
if grep -a -qE "TRAP: vector" "$LOG"; then
    echo "[pf_race] FAIL: CPU exception (TRAP: vector) during the race" >&2
    grep -a -E "TRAP: vector" "$LOG" | head -5 >&2
    fail=1
else
    echo "[pf_race] PASS: no CPU exception traps"
fi

# (e) no panic.
if grep -a -qE "PANIC|panic:|BUG:" "$LOG"; then
    echo "[pf_race] FAIL: kernel panic during the race" >&2
    grep -a -E "PANIC|panic:|BUG:" "$LOG" | head -5 >&2
    fail=1
else
    echo "[pf_race] PASS: no kernel panics"
fi

# Surface the guard's hit count (informational — N==0 is a valid PASS).
grep -a -E "\[pf_race\] SMP spurious not-present faults recovered" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | tail -1 || true

if [ "$fail" -ne 0 ]; then
    echo "[pf_race] FAIL (qemu rc=$rc)"
    echo "[pf_race] --- last 40 log lines ---"
    tail -40 "$LOG" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' >&2
    exit 1
fi

echo "[pf_race] PASS — two CPUs raced demand faults on a shared address space with no false SIGSEGV"
