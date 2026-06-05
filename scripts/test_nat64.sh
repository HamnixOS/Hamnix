#!/usr/bin/env bash
# scripts/test_nat64.sh — native stateful NAT64 (RFC 6146 + the RFC 6145
# stateless IP/ICMP translation algorithm) self-test.
#
# Boots the kernel once with /etc/nat64-test planted (ENABLE_NAT64_TEST=1).
# init/main.ad at boot:37.nat64 calls nat64_selftest() (drivers/net/nat64.ad),
# a fully in-memory translator test (NO external NIC required) that PROVES the
# core of NAT64 (RFC 6146):
#
#   * RFC 6052 address mapping with the Well-Known Prefix 64:ff9b::/96: an IPv4
#     address X.Y.Z.W is embedded as 64:ff9b::X.Y.Z.W (last 32 bits) and
#     extracted back, validating the prefix on the v6 side.
#   * A stateful Binding Information Base / session table (RFC 6146 §3.2): the
#     first outbound IPv6->IPv4 packet CREATES a session keyed by the 5-tuple
#     and assigns an IPv4 pool source port; the matching inbound IPv4->IPv6
#     reply is LOOKED UP against the table and translated back to the original
#     IPv6 host.
#   * IPv6->IPv4 translation (RFC 6145 §5): rebuilds a 20-byte IPv4 header
#     (0x45, TTL=HopLimit-1, proto, src=pool, dst=embedded v4), recomputes the
#     IPv4 header checksum and the UDP/TCP pseudo-header L4 checksum.
#   * IPv4->IPv6 translation (RFC 6145 §4): builds a valid 40-byte IPv6 header
#     (version 6, flow label 0, hop limit=TTL-1), src=64:ff9b::<remote>,
#     session-matched dst, recomputes the L4 checksum over the IPv6 pseudo-hdr.
#   * ICMP<->ICMPv6 Echo translation (RFC 6145 §4.2/§5.2): type 8/0 <-> 128/129
#     with the Identifier acting as the session port and the ICMPv6 checksum
#     (which covers the IPv6 pseudo-header) recomputed.
#   * Security: an inbound IPv4 packet with NO matching session is DROPPED (no
#     spurious binding); an outbound v6 destination NOT carrying the prefix is
#     REJECTED; every translated packet's checksums actually validate.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [nat64] PASS
# Fail marker:  [nat64] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_nat64] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_nat64] (2/3) Build kernel with /etc/nat64-test marker"
INIT_ELF=build/user/init.elf ENABLE_NAT64_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_nat64] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nat64] --- captured (nat64 lines) ---"
grep -E '\[nat64\]|\[boot:37.nat64\]' "$LOG" || true
echo "[test_nat64] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_nat64] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[nat64] FAIL" "$LOG"; then
    echo "[test_nat64] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.nat64] FAIL" "$LOG"; then
    echo "[test_nat64] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_nat64] PASS: $label"
    else
        echo "[test_nat64] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[nat64] self-test start"
check "address mapping rfc6052"   "[nat64] PASS address-mapping-rfc6052"
check "udp outbound 6to4"         "[nat64] PASS udp-outbound-6to4"
check "udp inbound 4to6"          "[nat64] PASS udp-inbound-4to6"
check "tcp flow both ways"        "[nat64] PASS tcp-flow-6to4-and-4to6"
check "icmp echo translate"       "[nat64] PASS icmp-echo-translate"
check "reject inbound no session" "[nat64] PASS reject-inbound-no-session"
check "reject missing prefix"     "[nat64] PASS reject-missing-prefix"
check "nat64 PASS banner"         "[nat64] PASS"
check "boot gate PASS"            "[boot:37.nat64] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_nat64] FAIL"
    exit 1
fi

echo "[test_nat64] PASS — native stateful NAT64 (RFC 6146 + RFC 6145): the RFC 6052 Well-Known Prefix 64:ff9b::/96 maps IPv4 into IPv6 and back (prefix validated); the first outbound IPv6->IPv4 packet creates a 5-tuple session assigning an IPv4 pool source port, and the matching inbound IPv4->IPv6 reply is matched against the session table and translated back to the original IPv6 host; UDP, TCP and ICMP Echo are translated in both directions, rebuilding the IPv4/IPv6 headers (version/IHL, TTL=HopLimit-1, flow label 0), rewriting addresses + the pool port, and recomputing the IPv4 header checksum plus the UDP/TCP/ICMPv6 pseudo-header checksums so they validate; an inbound IPv4 packet with no matching session is dropped (no spurious binding) and an outbound v6 destination lacking the prefix is rejected"
