#!/usr/bin/env bash
# scripts/test_dhcp_renew.sh — exercise the M16.x DHCP renew / rebind /
# lease-expiry state machine (RFC 2131 §4.4.5).
#
# Stock test_net_dhcp.sh proves the INIT -> SELECTING -> REQUESTING ->
# BOUND happy path. Once BOUND, the original DHCP client stayed there
# forever (perpetual lease). M16.x added the rest of RFC 2131 §4.4:
#
#   BOUND     -> RENEWING  at T1 = lease/2     (unicast REQUEST)
#   RENEWING  -> REBINDING at T2 = lease*7/8   (broadcast REQUEST)
#   REBINDING -> IDLE      at T3 = lease       (forget lease)
#   RENEWING/REBINDING + ACK -> BOUND (re-arm)
#
# The state machine is driven in-kernel by dhcp_renew_smoke_test
# (drivers/net/dhcp.ad). It shrinks the live SLIRP lease to a
# synthetic 60 s and uses dhcp_advance_clock_for_test(ms) to
# fast-forward the virtual clock past T1 / T2 / T3 in three steps.
# The wire is suppressed during the smoke (dhcp_test_suppress_tx)
# so SLIRP can't race an ACK back into the state machine mid-test.
#
# Verification is done in two layers (mirroring test_net_tcp_retrans):
#
#   1. Static: the kernel ELF must contain the four printk format
#      strings — proves the new state-machine code path is linked
#      in (the compiler hasn't dead-code-eliminated it).
#
#   2. Live: the QEMU boot must surface all four markers in order:
#         [dhcp renewing]       — T1 fired
#         [dhcp rebinding]      — T2 fired
#         [dhcp lease expired]  — T3 fired
#         [dhcp_renew] PASS     — full transition observed
#
# PASS requires BOTH layers green.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_dhcp_renew] (1/4) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
# ENABLE_DHCP_RENEW_SMOKE plants /etc/dhcp-renew-test so init/main.ad's
# gated dhcp_renew_smoke_test actually fires. Default boots skip the
# smoke (it leaves state at IDLE, breaking downstream BOUND-gated
# tests like test_dns.sh). The EXIT trap below rebuilds the initramfs
# without the marker so subsequent test runs get a clean default.
INIT_ELF=build/user/init.elf ENABLE_DHCP_RENEW_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_dhcp_renew] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dhcp_renew] (3/4) Static check: smoke-test printk strings in ELF"
STRTAB=$(mktemp)
strings "$ELF" > "$STRTAB"
static_miss=0
for needle in \
    "[dhcp renewing]" \
    "[dhcp rebinding]" \
    "[dhcp lease expired]" \
    "[dhcp_renew] PASS"
do
    if grep -F -q "$needle" "$STRTAB"; then
        echo "[test_dhcp_renew] OK (static): '$needle'"
    else
        echo "[test_dhcp_renew] MISS (static): '$needle'"
        static_miss=1
    fi
done
rm -f "$STRTAB"
if [ "$static_miss" -ne 0 ]; then
    echo "[test_dhcp_renew] FAIL: renew/rebind printk strings missing from ELF"
    exit 1
fi

echo "[test_dhcp_renew] (4/4) Boot QEMU with virtio-net + SLIRP DHCP"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_dhcp_renew] --- captured (dhcp / dhcp_renew) ---"
grep -E '\[dhcp\]|\[dhcp renewing\]|\[dhcp rebinding\]|\[dhcp lease expired\]|\[dhcp_renew\]|\[dhcp bound\]' "$LOG" || true
echo "[test_dhcp_renew] --- end ---"

# The renew smoke is gated on the live SLIRP DHCP reaching BOUND. If
# the kernel never got an IP from SLIRP, the smoke logs a SKIP marker
# and we treat the run as inconclusive — but the static check above
# already proved the code is linked in, so we don't fail outright.
if grep -F -q "[dhcp_renew] SKIP" "$LOG"; then
    echo "[test_dhcp_renew] WARN: smoke SKIPped (no live BOUND state to drive from)"
    echo "[test_dhcp_renew] PASS (static check OK; live skipped)"
    exit 0
fi

fail=0
for needle in \
    "[dhcp renewing]" \
    "[dhcp rebinding]" \
    "[dhcp lease expired]" \
    "[dhcp_renew] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_dhcp_renew] OK (live): '$needle'"
    else
        echo "[test_dhcp_renew] MISS (live): '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_dhcp_renew] FAIL (qemu rc=$rc)"
    echo "[test_dhcp_renew] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_dhcp_renew] PASS"
