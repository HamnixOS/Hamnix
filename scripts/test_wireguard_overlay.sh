#!/usr/bin/env bash
# scripts/test_wireguard_overlay.sh — native WireGuard-over-UDP wired path.
#
# Boots the kernel once with /etc/wireguard-overlay-test planted
# (ENABLE_WIREGUARD_OVERLAY_TEST=1). init/main.ad at
# boot:37.wireguard_overlay calls wireguard_overlay_selftest()
# (drivers/net/wireguard.ad).
#
# Unlike scripts/test_wireguard.sh (which round-trips encap/decap inside
# wireguard.ad only and never leaves the protocol's own buffers) this
# test PROVES the cross-driver wiring: a WG virtual interface's egress
# hook is wg_iface_xmit() which calls wg_transport_seal() to produce a
# real ChaCha20-Poly1305 transport message and parks it on an in-VM
# UDP-shape wire ring (src/dst ip + port + payload). The wire pump
# (wg_wire_pump) drains one outer datagram, port-51820-demuxes it
# against a 2-endpoint listener registry, and feeds the payload into
# wg_udp_rx() which dispatches by WG type byte (INIT=1, RESPONSE=2,
# TRANSPORT=4) and on TRANSPORT calls wg_transport_open() to deliver
# the inner packet at the peer's WG interface. The Noise IKpsk2
# handshake (initiation + response) ALSO rides the same wire — the
# whole protocol completes through the wire, no direct cross-endpoint
# call.
#
# This is the option-5 in-VM loopback chosen over a two-QEMU + tap
# setup (per the task brief): one box, deterministic, host-independent,
# but proves the same wiring property. The remaining gap is routing
# the outer UDP/IPv4 datagram through virtio_net_tx + udp_rx port-51820
# demux instead of the wire ring — that needs a listener registry in
# drivers/net/udp.ad (today the port demux is hardcoded for DHCP / DNS /
# the socket table).
#
# Pass marker:  [wireguard-overlay] PASS
# Fail marker:  [wireguard-overlay] FAIL  /  [boot:37.wireguard_overlay] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_wireguard_overlay] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wireguard_overlay] (2/3) Build kernel with /etc/wireguard-overlay-test marker"
INIT_ELF=build/user/init.elf ENABLE_WIREGUARD_OVERLAY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wireguard_overlay] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_wireguard_overlay] --- captured (wireguard-overlay lines) ---"
grep -E '\[wireguard-overlay\]|\[boot:37\.wireguard_overlay\]' "$LOG" || true
echo "[test_wireguard_overlay] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wireguard_overlay] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[wireguard-overlay] FAIL" "$LOG"; then
    echo "[test_wireguard_overlay] FAIL: kernel self-test reported a wiring failure" >&2
    fail=1
fi
if grep -qF "[boot:37.wireguard_overlay] FAIL" "$LOG"; then
    echo "[test_wireguard_overlay] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_wireguard_overlay] PASS: $label"
    else
        echo "[test_wireguard_overlay] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                "[wireguard-overlay] self-test start"
check "init on wire"                 "[wireguard-overlay] PASS init-on-wire"
check "init consumed via wire"       "[wireguard-overlay] PASS init-consumed-via-wire"
check "response on wire"             "[wireguard-overlay] PASS response-on-wire"
check "response consumed via wire"   "[wireguard-overlay] PASS response-consumed-via-wire"
check "transport keys match"         "[wireguard-overlay] PASS transport-keys-match"
check "A->B byte identical"          "[wireguard-overlay] PASS A-to-B-byte-identical"
check "B->A byte identical"          "[wireguard-overlay] PASS B-to-A-byte-identical"
check "wire counters balance"        "[wireguard-overlay] PASS wire-counters-balance"
check "overlay PASS banner"          "[wireguard-overlay] PASS"
check "boot gate PASS"               "[boot:37.wireguard_overlay] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_wireguard_overlay] FAIL"
    exit 1
fi

echo "[test_wireguard_overlay] PASS — native WireGuard wired through an in-VM UDP-shape wire: Noise_IKpsk2 handshake (init+response) and ChaCha20-Poly1305 transport datagrams cross between two endpoints (10.0.0.1:51820 <-> 10.0.0.2:51820) and deliver the inner packet byte-identical at the peer's WG interface"
