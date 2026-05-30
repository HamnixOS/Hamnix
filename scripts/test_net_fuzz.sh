#!/usr/bin/env bash
# scripts/test_net_fuzz.sh — network parser hardening / fuzz regression test.
#
# At boot, net_parse_fuzz_selftest() (appended to dns_selftest() in
# drivers/net/dns.ad, itself called from net_smoke_test() in
# init/main.ad) feeds CRAFTED MALFORMED PACKETS to each inbound parse
# path and asserts:
#
#   (a) the kernel does not crash or hang, AND
#   (b) each parser rejects / drops the malformed input correctly.
#
# Malformed inputs exercised:
#
#   DNS-runt             : DNS response < DNS_HDR_LEN (12) bytes.
#   DNS-ptr-self-skip    : Compression pointer pointing to itself —
#                          _dns_skip_qname must not loop.
#   DNS-ptr-self-read    : Same, but via _dns_read_name — must return -1.
#   DNS-ptr-cycle        : A→B→A forward-pointing cycle — rejected at
#                          first hop (not strictly backward).
#   DNS-truncated-RDATA  : RDATA field claims 4 bytes but only 3 are
#                          in the buffer; no A-record must be stored.
#   IP-runt              : IPv4 packet < 20 bytes (minimum header).
#   IP-bad-version       : Version field ≠ 4.
#   IP-bad-ihl           : IHL < 5 (below minimum header length).
#   IP-totlen-lt-ihl     : total_length < ihl*4 (NEW check — was missing).
#   IP-overflow-totlen   : total_length = 0xFFFF but buffer is 40 bytes;
#                          parser must clamp to buffer, not walk off end.
#   ARP-runt             : ARP frame < 42 bytes.
#   ARP-bad-htype        : htype != 0x0001 (not Ethernet) — must reject.
#   DHCP-runt            : DHCP payload < 240 bytes.
#   DHCP-option-overflow : Option olen claims 200 bytes; only 5 in buffer.
#   ICMP-runt            : ICMP message < 8 bytes (minimum header).
#   ICMP-echo-exact-buf  : Echo request of exactly ICMP_BUF_BYTES; the
#                          >= guard (fixed from >) must reject it.
#   DNS-ptr-oob          : Compression pointer past buffer end — -1 return.
#
# The survival sentinel "[net-fuzz] PASS-ALL" must appear in the log.
# Individual sub-test lines "[net-fuzz] <name> PASS" are also checked.
#
# QEMU timeout is generous (120 s) because the test runs under TCG and
# the boot sequence (ARP → DHCP → ICMP ping → DNS) completes before the
# fuzz tests run.  The kernel halts after net_smoke_test; 120 s is well
# above the observed ~8 s net smoke time on this host.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_fuzz] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_fuzz] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_fuzz] (3/3) Boot QEMU and run net-fuzz selftest"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

# Strip ANSI/VT100 escape sequences from the log so grep can match
# the raw text even when GRUB or the framebuffer driver emits control
# codes mid-line. `strings` alone is not enough: ANSI codes split a
# line like "[000162] [net-fuzz] DNS-runt PASS" into two sub-strings
# neither of which contains the full target substring.
CLEAN_LOG=$(mktemp)
# Remove ESC[ ... m sequences (colour), ESC[ ... H (cursor pos),
# ESC[2J (clear screen), and bare ESC+ one char sequences.
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.//g' "$LOG" > "$CLEAN_LOG"

echo "[test_net_fuzz] --- captured (net-fuzz lines) ---"
grep -E '\[net-fuzz\]|\[dns-selftest\]' "$CLEAN_LOG" || true
echo "[test_net_fuzz] --- end ---"

fail=0

# Check every individual sub-test PASS line.
for needle in \
    "[net-fuzz] DNS-runt PASS" \
    "[net-fuzz] DNS-ptr-self-skip PASS" \
    "[net-fuzz] DNS-ptr-self-read PASS" \
    "[net-fuzz] DNS-ptr-cycle PASS" \
    "[net-fuzz] DNS-truncated-RDATA PASS" \
    "[net-fuzz] IP-runt PASS" \
    "[net-fuzz] IP-bad-version PASS" \
    "[net-fuzz] IP-bad-ihl PASS" \
    "[net-fuzz] IP-totlen-lt-ihl PASS" \
    "[net-fuzz] IP-overflow-totlen PASS" \
    "[net-fuzz] ARP-runt PASS" \
    "[net-fuzz] ARP-bad-htype PASS" \
    "[net-fuzz] DHCP-runt PASS" \
    "[net-fuzz] DHCP-option-overflow PASS" \
    "[net-fuzz] ICMP-runt PASS" \
    "[net-fuzz] ICMP-echo-exact-buf PASS" \
    "[net-fuzz] DNS-ptr-oob PASS" \
    "[net-fuzz] PASS-ALL"
do
    if grep -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_net_fuzz] OK: '$needle'"
    else
        echo "[test_net_fuzz] MISS: '$needle'"
        fail=1
    fi
done
rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    echo "[test_net_fuzz] FAIL (qemu rc=$rc)"
    echo "[test_net_fuzz] --- full log (ansi-stripped) ---"
    CLEAN2=$(mktemp)
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.//g' "$LOG" > "$CLEAN2"
    head -300 "$CLEAN2"
    rm -f "$CLEAN2"
    exit 1
fi

echo "[test_net_fuzz] PASS"
