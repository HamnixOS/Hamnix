#!/usr/bin/env bash
# scripts/test_max_cpus_lockstep.sh — CPU-cap single-source drift guard.
#
# BACKGROUND. The logical-CPU hard cap is the literal dimension of every
# per-CPU array in the kernel (cpu_apic_id, rq_locks, rq_head, the per-CPU
# runqueue tables, the ACPI lapic cache, the AP idle-slot map). Adder forbids
# initialising one global from another, so the cap is repeated as FOUR separate
# literals across four files:
#
#   arch/x86/kernel/smp.ad   MAX_CPUS       (the designated single source)
#   kernel/sched/core.ad     NR_RQ          (per-CPU runqueue array dim)
#   kernel/sched/core.ad     AP_MAX_CPUS    (AP idle-kthread slot map)
#   drivers/acpi/acpi.ad     ACPI_MAX_CPUS  (MADT lapic cache dim)
#
# If a future change bumps one (e.g. to support a >16-CPU server) but misses a
# sibling, a high logical-CPU id writes past a still-16-wide array — silent
# corruption. This STATIC (grep, VM-free) guard fails the build the moment the
# four diverge, mirroring the NTASKS per-task-tables drift guard discipline.
#
# It does NOT pin the value to 16 — raising the cap is fine, as long as ALL
# FOUR move together AND the per-CPU array dims (which equal the constant) are
# bumped in lockstep too.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

note() { echo "[test_max_cpus] $*"; }
fail=0
bad()  { echo "[test_max_cpus] FAIL: $*" >&2; fail=1; }

extract() {
    # extract <file> <const-name> -> prints the integer literal or empty
    grep -Eo "^${2}:[[:space:]]+uint64[[:space:]]*=[[:space:]]*[0-9]+" "$1" \
        | grep -Eo '[0-9]+$' | head -1
}

MAX_CPUS=$(extract arch/x86/kernel/smp.ad MAX_CPUS)
NR_RQ=$(extract kernel/sched/core.ad NR_RQ)
AP_MAX_CPUS=$(extract kernel/sched/core.ad AP_MAX_CPUS)
ACPI_MAX_CPUS=$(extract drivers/acpi/acpi.ad ACPI_MAX_CPUS)

note "MAX_CPUS=${MAX_CPUS:-?} NR_RQ=${NR_RQ:-?} AP_MAX_CPUS=${AP_MAX_CPUS:-?} ACPI_MAX_CPUS=${ACPI_MAX_CPUS:-?}"

for v in "$MAX_CPUS" "$NR_RQ" "$AP_MAX_CPUS" "$ACPI_MAX_CPUS"; do
    [ -n "$v" ] || bad "a CPU-cap constant could not be located (parse error)"
done

if [ -n "$MAX_CPUS" ]; then
    [ "$NR_RQ" = "$MAX_CPUS" ]         || bad "NR_RQ ($NR_RQ) != MAX_CPUS ($MAX_CPUS)"
    [ "$AP_MAX_CPUS" = "$MAX_CPUS" ]   || bad "AP_MAX_CPUS ($AP_MAX_CPUS) != MAX_CPUS ($MAX_CPUS)"
    [ "$ACPI_MAX_CPUS" = "$MAX_CPUS" ] || bad "ACPI_MAX_CPUS ($ACPI_MAX_CPUS) != MAX_CPUS ($MAX_CPUS)"
fi

# The per-CPU array dims in core.ad must equal the cap (rq_locks / rq_head).
if [ -n "$NR_RQ" ]; then
    if ! grep -Eq "^rq_locks:[[:space:]]*Array\[${NR_RQ},[[:space:]]*uint32\]" kernel/sched/core.ad; then
        bad "rq_locks array dim != NR_RQ ($NR_RQ)"
    fi
    if ! grep -Eq "^rq_head:[[:space:]]*Array\[${NR_RQ},[[:space:]]*uint64\]" kernel/sched/core.ad; then
        bad "rq_head array dim != NR_RQ ($NR_RQ)"
    fi
fi
# The ACPI lapic cache dim must equal ACPI_MAX_CPUS.
if [ -n "$ACPI_MAX_CPUS" ]; then
    if ! grep -Eq "^acpi_lapic_ids:[[:space:]]*Array\[${ACPI_MAX_CPUS},[[:space:]]*uint32\]" drivers/acpi/acpi.ad; then
        bad "acpi_lapic_ids array dim != ACPI_MAX_CPUS ($ACPI_MAX_CPUS)"
    fi
fi
# smp.ad's cpu_apic_id dim must equal MAX_CPUS.
if [ -n "$MAX_CPUS" ]; then
    if ! grep -Eq "^cpu_apic_id:[[:space:]]*Array\[${MAX_CPUS},[[:space:]]*uint32\]" arch/x86/kernel/smp.ad; then
        bad "cpu_apic_id array dim != MAX_CPUS ($MAX_CPUS)"
    fi
fi

# Sanity: AP bring-up is MADT-count-driven, not a fixed loop to MAX_CPUS.
if ! grep -q "acpi_cpu_count()" arch/x86/kernel/smp.ad; then
    bad "smp_boot_aps no longer drives AP count from acpi_cpu_count() (MADT)"
fi

if [ "$fail" -eq 0 ]; then
    note "PASS — all CPU-cap constants + per-CPU array dims agree; AP bring-up is MADT-driven"
    exit 0
fi
note "FAIL"
exit 1
