#!/usr/bin/env bash
# scripts/test_net_r8169.sh — V1 end-to-end test for the bare-metal
# r8169-family Realtek NIC driver.
#
# Boots the kernel with a QEMU rtl8139 device attached to SLIRP.
# `pci_scan()` (in drivers/pci/pci.ad) calls `r8169_init()` once
# the bus walk completes; the driver matches Realtek vendor 0x10EC
# plus device 0x8139 (RTL8139, the only Realtek model QEMU
# emulates in modern `qemu-system-x86_64`), enables the PCI IO +
# bus-master pair, reads BAR0 as the 16-byte PIO window, software-
# resets the chip, reads the MAC from IDR0..IDR5, allocates the
# circular RX buffer (8 KiB + 16 overhead + 1500 slack), plants its
# physical address at RBSTART, configures RCR (AB + APM + WRAP +
# RBLEN=8K), and flips CMD.RE|TE to enable RX + TX.
#
# After init the kernel submits one 64-byte ARP probe (10.0.2.15 ->
# 10.0.2.2) through the 4-slot 8139 TX path; SLIRP answers with an
# ARP reply that lands in the circular RX buffer and r8169_poll()
# delivers it to eth_rx(). The test asserts both the tx-ok log and
# at least one RX-packet log, matching the V1 acceptance bar that
# `scripts/test_net_e1000e.sh` already enforces for the Intel NIC.
#
# Why rtl8139 and not rtl8169? QEMU's available Realtek device list
# (verify with `qemu-system-x86_64 -device help | grep -i rtl`) on
# modern installs is only `rtl8139`. The Gigabit RTL8168 / RTL8169
# (MMIO + 16-descriptor ring) code lives in the same source file
# under the `_r8169_init_gigabit` branch; it dispatches on PCI
# device-id (0x8167 / 0x8168 / 0x8169) and is exercised only on
# real hardware — Linux groups all Realtek Ethernet variants under
# `drivers/net/ethernet/realtek/r8169_main.c` regardless of
# generation, and we follow that grouping.
#
# The test asserts:
#   1. "[r8169] controller found bdf=" — PCI vendor/device match
#      + class-triple cross-check both succeeded.
#   2. "[r8169] mac=52:54:00:12:34:56" — IDR0..IDR5 read worked
#      against the MAC QEMU loaded from the `mac=` argument.
#   3. "[r8169] RX ring ready" — the 8 KiB + slack RX buffer
#      allocated cleanly and RBSTART + RCR are programmed.
#   4. "[r8169] init done" — top-level driver entry returned 0.
#   5. "[r8169] tx ok len=64" — single 64-byte ARP probe made it
#      onto the wire (TSD OWN+TOK writeback observed).
#   6. "[r8169] RX packet: len=" — at least one inbound frame
#      delivered (SLIRP's ARP reply).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_r8169] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_r8169] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_r8169] (3/3) Boot QEMU with rtl8139 attached"
LOG=$(mktemp)
# Restore the default /init at the end so subsequent tests / runs
# don't see whatever initramfs state we leave behind.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device rtl8139,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_r8169] --- captured (r8169 lines) ---"
grep -E '\[r8169\]' "$LOG" || true
echo "[test_net_r8169] --- end ---"

fail=0
for needle in \
    "[r8169] controller found bdf=" \
    "[r8169] mac=52:54:00:12:34:56" \
    "[r8169] RX ring ready" \
    "[r8169] init done" \
    "[r8169] tx ok len=64" \
    "[r8169] RX packet: len="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_r8169] OK: '$needle'"
    else
        echo "[test_net_r8169] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_r8169] FAIL (qemu rc=$rc)"
    echo "[test_net_r8169] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_r8169] PASS"
