#!/usr/bin/env bash
# scripts/test_net_virtio_mrg.sh — maturity test for the bare-metal
# virtio-net driver: mergeable RX buffers (VIRTIO_NET_F_MRG_RXBUF),
# RX-refill robustness, and multiqueue control (VIRTIO_NET_F_MQ via the
# control virtqueue VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET command).
#
# Boots the kernel with a QEMU virtio-net device that ADVERTISES the
# mature feature set:
#   mrg_rxbuf=on  -> the device offers F_MRG_RXBUF; the driver switches
#                    to the 12-byte mergeable virtio_net_hdr and the
#                    num_buffers-driven RX reassembly path.
#   mq=on,vectors=6 -> the device offers F_MQ + F_CTRL_VQ; the driver
#                    reads max_virtqueue_pairs from config space, sets
#                    up the control virtqueue, and issues
#                    VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET(1).
#
# The kernel's net_smoke_test() path probes PCI, negotiates the
# features, transmits an ARP request + runs a full DHCP
# discover/offer/request/ack exchange against SLIRP's emulated gateway,
# and reassembles every device-delivered frame through the mergeable
# path. virtio_net_maturity_report() then emits the PASS banners off
# the LIVE counters (rx_packets, refills, rx_outstanding) — proving a
# real frame was received and reassembled, never synthesized.
#
# Greps for:
#   [virtio-net] negotiated F_MRG_RXBUF (12-byte hdr)
#   [virtio-net] CTRL_MQ pairs=1 acked
#   [virtio-net] PASS mq-ctrl
#   [virtio-net] PASS mrg-rxbuf
#   [virtio-net] PASS refill

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_virtio_mrg] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_virtio_mrg] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_virtio_mrg] (3/3) Boot QEMU with mergeable+MQ virtio-net"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56,mrg_rxbuf=on,mq=on,vectors=6 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_virtio_mrg] --- captured (virtio-net lines) ---"
grep -E '\[virtio-net\]|eth_rx|\[dhcp\]' "$LOG" || true
echo "[test_net_virtio_mrg] --- end ---"

fail=0
for needle in \
    "[virtio-net] negotiated F_MRG_RXBUF (12-byte hdr)" \
    "[virtio-net] PASS mq-ctrl" \
    "[virtio-net] PASS mrg-rxbuf" \
    "[virtio-net] PASS refill"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_virtio_mrg] OK: '$needle'"
    else
        echo "[test_net_virtio_mrg] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_virtio_mrg] FAIL (qemu rc=$rc)"
    echo "[test_net_virtio_mrg] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_virtio_mrg] PASS"
