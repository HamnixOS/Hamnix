#!/usr/bin/env bash
# scripts/test_net_e1000e.sh — end-to-end test for the bare-metal
# e1000e (Intel 82574L family) PCI driver.
#
# Boots the kernel with a QEMU e1000e device attached to SLIRP.
# `pci_scan()` (in drivers/pci/pci.ad) calls `e1000e_init()` once
# the bus walk completes; the driver matches Intel vendor 0x8086
# plus device 0x10D3 (82574L, QEMU's `-device e1000e` model),
# enables PCI MEM + bus-master, maps BAR0, software-resets via
# CTRL.RST, sets SLU+ASDE, reads MAC from RAL[0]/RAH[0], builds
# 256-slot RX + TX descriptor rings, arms RCTL.EN + TCTL.EN+PSP,
# and submits one ARP request for 10.0.2.2. The SLIRP gateway
# answers; the reply lands in our RX ring and eth_rx() runs.
#
# This is the V1 round-trip bring-up — RX + TX both exercised
# end-to-end against the existing ARP/IP scaffold. virtio-net
# (M16.88) is still the canonical bring-up NIC for the full net
# stack tests; this test stops at "one frame out, one frame in".
#
# The test asserts:
#   1. "[e1000e] controller found bdf=" — PCI vendor/device match
#      + class-triple cross-check both succeeded.
#   2. "[e1000e] reset complete" — CTRL.RST bounded wait observed
#      the device clearing the bit (real-hw hygiene; on QEMU
#      this fires within a handful of MMIO reads).
#   3. "[e1000e] mac=52:54:00:12:34:56" — RAL0/RAH0 read worked
#      against the MAC QEMU loaded from the `mac=` argument.
#   4. "[e1000e] link up" — STATUS.LU bit set after SLU+ASDE.
#   5. "[e1000e] RX ring ready (256 descriptors)" — the RX
#      descriptor ring + per-descriptor 2 KiB buffer pre-population
#      path completed without a kmalloc failure.
#   6. "[e1000e] TX ring ready (256 descriptors)" — TX ring
#      configured, TCTL.EN+PSP armed.
#   7. "[e1000e] init done" — top-level driver entry returned 0.
#   8. "[e1000e] tx ok len=64" — single 64-byte ARP request made
#      it onto the wire (descriptor DD writeback observed).
#   9. "[e1000e] RX packet: len=" — at least one inbound frame
#      delivered (SLIRP's ARP reply to our probe).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_e1000e] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_e1000e] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_e1000e] (3/3) Boot QEMU with e1000e attached"
LOG=$(mktemp)
# Restore the default /init at the end so subsequent tests / runs
# don't see whatever initramfs state we leave behind.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device e1000e,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_e1000e] --- captured (e1000e lines) ---"
grep -E '\[e1000e\]' "$LOG" || true
echo "[test_net_e1000e] --- end ---"

fail=0
for needle in \
    "[e1000e] controller found bdf=" \
    "[e1000e] reset complete" \
    "[e1000e] mac=52:54:00:12:34:56" \
    "[e1000e] link up" \
    "[e1000e] RX ring ready (256 descriptors)" \
    "[e1000e] TX ring ready (256 descriptors)" \
    "[e1000e] init done" \
    "[e1000e] tx ok len=64" \
    "[e1000e] RX packet: len="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_e1000e] OK: '$needle'"
    else
        echo "[test_net_e1000e] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_e1000e] FAIL (qemu rc=$rc)"
    echo "[test_net_e1000e] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_e1000e] PASS"
