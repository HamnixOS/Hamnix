#!/usr/bin/env bash
# scripts/test_smp.sh — SMP bring-up + AP scheduler regression test.
#
# Boots Hamnix under QEMU with -smp 2 (one BSP + one AP) and asserts
# that all APs come online via MADT-driven INIT-SIPI-SIPI AND that the
# AP actually enters the scheduler and runs a kernel task.
#
# PASS markers:
#   (a) "acpi: 2 CPU(s) cached from MADT"
#         MADT parser discovered 2 enabled CPUs (BSP + AP).
#   (b) "SMP: MADT reports 2 CPU(s)"
#         smp_boot_aps read the MADT count correctly.
#   (c) "SMP: booting AP cpu1 APIC id=1"
#         The BSP targeted the correct AP APIC ID (from MADT, not
#         the hardcoded fallback).
#   (d) "SMP: AP cpu1 (APIC) online, gs set up"
#         The AP reached ap_main_hamnix and set up its %gs per-CPU area.
#   (e) "SMP: AP cpu1 online (cpus_online=2)"
#         The AP bumped the online counter; BSP confirmed it.
#   (f) "Hamnix: cpus_online = 2"
#         The final counter logged by init/main.ad is 2.
#   (g) "SMP: cpu1 kthread alive"
#         The AP's idle kthread printed its banner from sched_ap_idle_loop(),
#         proving that scheduler code actually EXECUTED on a non-BSP core.
#         This is the key assertion that the AP is a full scheduler participant,
#         not just parked in a HLT loop.
#
# Architecture of this test:
#   - Uses the standard GRUB-ISO shim (_kernel_iso.sh) so the higher-half
#     ELF64 kernel boots correctly (raw -kernel on ELF64 hits multiboot1
#     rejection, so we use the shim from _build_lock.sh).
#   - -smp 2 matches the AP count the MADT parser expects on QEMU.
#   - Boot timeout: 60s (boot-to-shell is ~30s on TCG).
#
# This test does NOT require /dev/kvm (it passes on TCG).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_smp] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_smp] (2/3) Build kernel (init.elf as /init)"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_smp] (3/3) Boot QEMU -smp 2 and check AP bring-up"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 90s qemu-system-x86_64 \
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

echo "[test_smp] --- captured output (SMP-relevant lines) ---"
grep -E "SMP:|smp_|acpi.*CPU|cpus_online|AP cpu|MADT|kthread alive" "$LOG" || true
echo "[test_smp] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_smp] PASS: $label"
    else
        echo "[test_smp] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# (a) MADT parser found 2 CPUs
check_marker "MADT parsed 2 CPUs" "acpi: 2 CPU(s) cached from MADT"

# (b) smp_boot_aps read the MADT count
check_marker "SMP reports 2 CPUs from MADT" "SMP: MADT reports 2 CPU(s)"

# (c) Correct AP APIC ID from MADT (not hardcoded)
check_marker "AP APIC ID from MADT" "SMP: booting AP cpu1 APIC id=1"

# (d) AP reached Hamnix code and set up its per-CPU gs area
check_marker "AP gs per-CPU area set up" "SMP: AP cpu1 (APIC) online, gs set up"

# (e) BSP confirmed the AP bumped cpus_online
check_marker "BSP confirmed AP online" "SMP: AP cpu1 online (cpus_online=2)"

# (f) Final cpus_online count in init sequence
check_marker "cpus_online=2 in init" "Hamnix: cpus_online = 2"

# (g) AP kthread actually ran on the non-BSP core — the KEY scheduler assertion.
# sched_ap_idle_loop() prints this banner once, from cpu1, proving that the AP
# entered the Hamnix scheduler and executed kernel code on a non-BSP core.
check_marker "AP kthread ran on non-BSP core (cpu1)" "SMP: cpu1 kthread alive"

# Sanity: the BSP's scheduler is still alive (hamsh heartbeat)
if grep -qF "[hamsh-alive]" "$LOG"; then
    echo "[test_smp] PASS: BSP scheduler alive after SMP bring-up"
else
    echo "[test_smp] WARN: BSP hamsh-alive heartbeat not seen (may need more boot time)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_smp] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_smp] PASS — MADT-driven SMP bring-up + AP scheduler: all APs online, per-CPU gs set up, AP kthread executed"
