#!/usr/bin/env bash
# scripts/test_drivers_irq.sh — verify per-vector IRQ wiring lands on
# the wire for the bare-metal drivers (AHCI, NVMe, e1000e, r8169).
# M16.113 added the IOAPIC + per-vector handler-registration
# mechanism and proved it on virtio-net at vector 0x40; the device
# drivers each claim their own vector:
#
#     AHCI    = 0x41   (IOAPIC INTx)
#     NVMe    = 0x42   (IOAPIC INTx)
#     r8169   = 0x44   (IOAPIC INTx, RTL8139)
#     e1000e  = 0x47   (MSI — bypasses the IOAPIC)
#
# Vector 0x43 is now claimed by virtio-blk (kernel roadmap §9); the
# e1000e INTx slot it used to hold was retired when e1000e moved to
# single-vector MSI.
#
# Each driver registers its irq_handler in the per-vector table; the
# IOAPIC-routed ones (AHCI / NVMe / r8169) also program a redirection
# entry, while e1000e programs an MSI capability instead. The polled
# paths (ahci_smoke_test poll, nvme polled CQ phase drain,
# e1000e_poll, r8169_poll) all stay as safety-net fallbacks.
#
# The test attaches ALL four QEMU devices simultaneously so a single
# boot exercises every code path, then asserts each driver's IRQ-wire
# banner + its "[irq] handler registered for vector 0x4X" line.
#
# RX packet / completion observation is NOT asserted — SLIRP doesn't
# always provoke a real IRQ in QEMU TCG before the assertion window
# closes, and we don't want a flake gate. The test bar is "the IRQ
# wiring registered successfully"; the corresponding regression tests
# (test_ahci, test_nvme, test_net_e1000e, test_net_r8169) cover the
# data-path side.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_drivers_irq] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_drivers_irq] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_drivers_irq] (3/4) Mint scratch disks for SATA + NVMe"
SATA=$(mktemp --suffix=.irq-sata)
NVME=$(mktemp --suffix=.irq-nvme)
dd if=/dev/zero of="$SATA" bs=1M count=1 status=none
dd if=/dev/zero of="$NVME" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$SATA" bs=1 seek=510 conv=notrunc status=none
printf '\x55\xaa' | dd of="$NVME" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$SATA" "$NVME"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_drivers_irq] (4/4) Boot QEMU with AHCI + NVMe + e1000e + rtl8139"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$SATA",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -drive if=none,file="$NVME",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnix1234 \
    -netdev user,id=n0 \
    -device e1000e,netdev=n0,mac=52:54:00:12:34:56 \
    -netdev user,id=n1 \
    -device rtl8139,netdev=n1,mac=52:54:00:12:34:57 \
    -m 256M -smp 2 -nographic -no-reboot -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_drivers_irq] --- captured (ioapic / irq / driver banners) ---"
grep -aE '\[ioapic\]|\[irq\]|\[ahci\] irq |\[nvme\] irq |\[e1000e\] (irq|MSI) |\[r8169\] irq ' "$LOG" || true
echo "[test_drivers_irq] --- end ---"

fail=0
for needle in \
    "[ahci] irq pin=" \
    "[nvme] irq pin=" \
    "[r8169] irq pin=" \
    "[irq] handler registered for vector 0x41" \
    "[irq] handler registered for vector 0x42" \
    "[irq] handler registered for vector 0x44" \
    "[irq] handler registered for vector 0x47"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_drivers_irq] OK: '$needle'"
    else
        echo "[test_drivers_irq] MISS: '$needle'"
        fail=1
    fi
done

# e1000e prefers single-vector MSI but falls back to IOAPIC INTx if
# the device exposes no MSI capability — accept either banner.
if grep -aE -q '\[e1000e\] MSI vector=|\[e1000e\] INTx fallback pin=' "$LOG"; then
    echo "[test_drivers_irq] OK: e1000e IRQ wired (MSI or INTx)"
else
    echo "[test_drivers_irq] MISS: e1000e IRQ not wired"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_drivers_irq] FAIL (qemu rc=$rc)"
    echo "[test_drivers_irq] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_drivers_irq] PASS"
