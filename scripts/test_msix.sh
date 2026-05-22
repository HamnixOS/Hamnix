#!/usr/bin/env bash
# scripts/test_msix.sh — verify the virtio-net MSI-X interrupt path
# (kernel roadmap §9).
#
# QEMU's virtio-net-pci advertises an MSI-X capability by default
# (`vectors=3`). The driver:
#   1. Walks the PCI capability list for the MSI-X capability
#      (cap ID 0x11).
#   2. Maps the MSI-X table from its BAR and programs one table
#      entry per virtqueue (RX/TX) plus one for config-change —
#      message address routes to LAPIC id 0, message data carries
#      the per-vector CPU vector (0x49 / 0x4A / 0x4B).
#   3. Enables the MSI-X capability, tells the device which table
#      entry each virtqueue maps to, and registers a per-vector
#      handler.
#
# The boot-time msix_smoke_test() then proves DELIVERY, not just the
# cap-walk code: it opens a brief `sti` window, transmits an ARP
# request (SLIRP's gateway answers), and confirms the RX MSI-X
# message lands as a real CPU interrupt — virtio_net_irq_count()
# bumps only if device -> LAPIC -> IDT -> do_irq -> the registered
# MSI-X handler completed.
#
# The test asserts:
#   1. "[virtio-net] MSI-X cap at"        → capability list walked
#   2. "[virtio-net] MSI-X table @"       → table BAR resolved
#   3. "[irq] handler registered for vector 0x49"
#                                         → per-queue vector handler
#   4. "[virtio-net] MSI-X wired:"        → all vectors wired
#   5. "[msix] delivery test PASS"        → an MSI-X message was
#                                            actually delivered as a
#                                            CPU interrupt
#   6. "[virtio-net] RX packet: len="     → the polled RX path still
#                                            works (safety net intact)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_msix] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_msix] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_msix] (3/3) Boot QEMU with MSI-X-capable virtio-net"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# vectors=3 is QEMU's default for virtio-net-pci; it is named here
# explicitly so the test intent (MSI-X-capable device) is obvious.
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56,vectors=3 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_msix] --- captured (virtio-net / msix / irq) ---"
grep -aE '\[virtio-net\]|\[msix\]|\[irq\]' "$LOG" || true
echo "[test_msix] --- end ---"

fail=0
for needle in \
    "[virtio-net] MSI-X cap at" \
    "[virtio-net] MSI-X table @" \
    "[irq] handler registered for vector 0x49" \
    "[virtio-net] MSI-X wired:" \
    "[msix] delivery test PASS" \
    "[virtio-net] RX packet: len="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_msix] OK: '$needle'"
    else
        echo "[test_msix] MISS: '$needle'"
        fail=1
    fi
done

# A #DF / trap during the brief sti window of the MSI-X delivery
# self-test would be a hard failure — assert no trap fired.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_msix] MISS: a CPU trap fired during the MSI-X test"
    fail=1
else
    echo "[test_msix] OK: no CPU trap during the sti window"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_msix] FAIL (qemu rc=$rc)"
    echo "[test_msix] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_msix] PASS"
