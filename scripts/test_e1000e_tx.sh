#!/usr/bin/env bash
# scripts/test_e1000e_tx.sh — regression guard for the e1000e TX path
# (M16.x: "net(e1000e): TX descriptor ring + transmit path").
#
# Boots the kernel with `-device e1000e` as the ONLY NIC. No
# virtio-net is attached, so virtio_net_init() returns -1 in
# net_smoke_test() and the else-branch takes over: e1000e_init()
# (called earlier from pci_scan) has registered itself as the
# eth_tx hook, so dhcp_discover() lifts the DHCPDISCOVER UDP
# datagram onto the wire via e1000e_tx().
#
# This is the Skull-Canyon-class real-hardware shape: the I219-LM
# is the only NIC the OS sees, and DHCP / ARP / TCP all have to
# reach the wire through e1000e_tx. Before the M16.x115 TX-hook
# wiring landed, eth_tx hard-coded virtio_net_tx and the e1000e
# driver only ran an explicit ARP probe — no DHCP, no IP traffic.
#
# Assertions:
#   1. "[e1000e] init done"            — driver came up.
#   2. "[eth] tx hook registered"      — e1000e registered with
#      the eth.ad dispatch (proves the dispatch wiring works;
#      virtio-net's later overwrite did not happen because the
#      device wasn't present).
#   3. "[e1000e] tx ok len=64"         — ARP probe TX worked.
#   4. "[e1000e] RX packet: len="      — SLIRP's ARP reply landed.
#   5. "[dhcp] sending DHCPDISCOVER"   — DHCP frame TX through
#      eth_tx (and so through the registered e1000e_tx hook).
#   6. "[dhcp] got ip=10.0.2.15"       — SLIRP's DHCP server
#      answered, dhcp_rx parsed the OFFER, _dhcp_send_request
#      TX'd the REQUEST through e1000e_tx, the ACK landed, and
#      the lease was installed. End-to-end TX-then-RX over
#      e1000e via the upper L3 stack.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_e1000e_tx] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_e1000e_tx] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_e1000e_tx] (3/3) Boot QEMU with e1000e as the ONLY NIC"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device e1000e,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_e1000e_tx] --- captured (e1000e / eth / dhcp) ---"
grep -E '\[e1000e\]|\[eth\]|\[dhcp\]|\[arp\]' "$LOG" || true
echo "[test_e1000e_tx] --- end ---"

fail=0
for needle in \
    "[e1000e] init done" \
    "[eth] tx hook registered" \
    "[e1000e] tx ok len=64" \
    "[e1000e] RX packet: len=" \
    "[dhcp] sending DHCPDISCOVER" \
    "[dhcp] got ip=10.0.2.15"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_e1000e_tx] OK: '$needle'"
    else
        echo "[test_e1000e_tx] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_e1000e_tx] FAIL (qemu rc=$rc)"
    echo "[test_e1000e_tx] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_e1000e_tx] PASS"
