#!/usr/bin/env bash
# scripts/test_percpu_cpuid_offset0.sh — per-CPU ABI invariant guard.
#
# Asserts that the logical CPU id slot `cpu_id_pcpu` sits at per-CPU byte
# OFFSET 0 in the built kernel's .data..percpu section, and is the FIRST
# slot after the template marker `__per_cpu_template_start`.
#
# WHY THIS MATTERS (regression #402): the hand-written low-level asm reads
# smp_processor_id() as a literal `mov %gs:0` — read_cpu_id_percpu
# (setup_percpu_asm.S), syscall_entry (syscall_64.S), tss_set_rsp0 /
# tss_get_rsp0 (tss_asm.S) and tss_set_ist1 (trap_asm.S). A cross-object
# `(cpu_id_pcpu - __per_cpu_template_start)` symbol-difference displacement
# is NOT relocatable at assemble time, so those sites depend on the codegen
# PINNING cpu_id_pcpu to offset 0 (compiler/codegen_x86.py). When the pin
# was absent, another Percpu global (local_timer_ticks) linked ahead of
# cpu_id_pcpu at offset 0; the asm then read the timer-tick counter as a
# CPU id, indexed a wild per_cpu_tss[] slot, loaded a garbage RSP0, and the
# first timer IRQ from userspace #GP'd → triple-fault on boot.
#
# This is a pure symbol-table check on an already-built kernel ELF; no QEMU
# boot, no KVM, fast and host-independent.
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

# Locate a built kernel ELF. Prefer the installer kernel; fall back to the
# installed-root kernel, then build one if neither exists.
KELF=""
for cand in build/hamnix-installer-kernel.elf \
            build/hamnix-installed-kernel.elf \
            build/hamnix.elf; do
    if [ -f "$cand" ]; then KELF="$cand"; break; fi
done

if [ -z "$KELF" ]; then
    echo "[test_percpu_cpuid_offset0] no kernel ELF found; building a kernel..." >&2
    python3 -m compiler.adder compile --target=x86_64-bare-metal \
        init/main.ad -o build/hamnix-percpu-check-kernel.elf
    KELF=build/hamnix-percpu-check-kernel.elf
fi

echo "[test_percpu_cpuid_offset0] checking $KELF"

# Pull the .data..percpu symbols, sorted by address.
SYMS="$(objdump -t "$KELF" | awk '$0 ~ /\.data\.\.percpu/ {print $1, $NF}' | sort)"

if [ -z "$SYMS" ]; then
    echo "[test_percpu_cpuid_offset0] FAIL: no .data..percpu symbols in $KELF" >&2
    exit 1
fi

start_addr="$(echo "$SYMS" | awk '$2=="__per_cpu_template_start"{print $1; exit}')"
cpuid_addr="$(echo "$SYMS" | awk '$2=="cpu_id_pcpu"{print $1; exit}')"

if [ -z "$start_addr" ]; then
    echo "[test_percpu_cpuid_offset0] FAIL: __per_cpu_template_start not found" >&2
    echo "$SYMS" >&2
    exit 1
fi
if [ -z "$cpuid_addr" ]; then
    echo "[test_percpu_cpuid_offset0] FAIL: cpu_id_pcpu not found" >&2
    echo "$SYMS" >&2
    exit 1
fi

# Offset = cpu_id_pcpu - __per_cpu_template_start (hex subtraction).
offset=$(( 0x$cpuid_addr - 0x$start_addr ))

echo "[test_percpu_cpuid_offset0] __per_cpu_template_start=0x$start_addr"
echo "[test_percpu_cpuid_offset0] cpu_id_pcpu           =0x$cpuid_addr"
echo "[test_percpu_cpuid_offset0] cpu_id_pcpu offset    =$offset"

if [ "$offset" -ne 0 ]; then
    echo "[test_percpu_cpuid_offset0] FAIL: cpu_id_pcpu must be at per-CPU" \
         "offset 0 (the %gs:0 ABI the cpu_id asm assumes), but it is at" \
         "offset $offset. See compiler/codegen_x86.py percpu pin and" \
         "arch/x86/kernel/setup_percpu_asm.S." >&2
    exit 1
fi

echo "[test_percpu_cpuid_offset0] PASS: cpu_id_pcpu pinned at per-CPU offset 0"
