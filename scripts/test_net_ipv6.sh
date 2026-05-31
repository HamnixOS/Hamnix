#!/usr/bin/env bash
# scripts/test_net_ipv6.sh — exercise the basic link-local IPv6 stack
# (task #156): fe80:: link-local address derivation, ICMPv6 Neighbor
# Discovery (NS -> NA), and ICMPv6 Echo (Echo Request -> Echo Reply).
#
# The kernel's net_smoke_test() runs ipv6_selftest() when the
# /etc/ipv6-test cpio marker is present (planted here via
# ENABLE_IPV6_SELFTEST=1). The self-test:
#   1. derives our fe80::/64 EUI-64 link-local address from the NIC MAC
#      and prints it;
#   2. synthesizes an ICMPv6 Neighbor Solicitation for that address and
#      feeds it through the REAL eth_rx -> ipv6_rx -> _icmp6_rx demux,
#      asserting a Neighbor Advertisement was built;
#   3. synthesizes an ICMPv6 Echo Request to that address and asserts an
#      Echo Reply was built.
#
# This is a DETERMINISTIC offline exercise of the v6 RX/TX path — it
# does not depend on QEMU SLIRP IPv6 behaviour. A trailing QEMU rc=124
# AFTER the markers print is a benign red herring (the kernel halts
# without powering off QEMU). We assert with `grep -a` because the boot
# log contains binary bytes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_ipv6] (1/3) Build userland + initramfs (with /etc/ipv6-test marker)"
bash scripts/build_user.sh >/dev/null
ENABLE_IPV6_SELFTEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_ipv6] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_ipv6] (3/3) Boot QEMU with virtio-net attached"
LOG=$(mktemp)
# Restore the default (marker-free) initramfs on exit so subsequent
# tests / runs don't see the /etc/ipv6-test marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_ipv6] --- captured (ipv6 / icmpv6 lines) ---"
grep -a -E '\[ipv6\]|\[icmpv6\]|\[ipv6-selftest\]' "$LOG" || true
echo "[test_net_ipv6] --- end ---"

fail=0
for needle in \
    "[ipv6] link-local address fe80:: derived: fe80:" \
    "[ipv6-selftest] NS->NA PASS" \
    "[ipv6-selftest] echo PASS" \
    "[ipv6-selftest] ALL PASS"
do
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_net_ipv6] OK: '$needle'"
    else
        echo "[test_net_ipv6] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_ipv6] FAIL (qemu rc=$rc)"
    echo "[test_net_ipv6] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_ipv6] PASS"
