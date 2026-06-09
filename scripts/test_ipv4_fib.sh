#!/usr/bin/env bash
# scripts/test_ipv4_fib.sh — focused IPv4 FIB regression: longest-prefix
# match (LPM) AND equal-cost multipath (ECMP) in a single boot.
#
# THE GAP THIS COVERS
# -------------------
# drivers/net/ip.ad used to know exactly TWO routes: the single on-link
# subnet (our address & netmask) was ARP'd directly, and EVERYTHING else
# went to one hardcoded default gateway. There was no forwarding
# information base — no way to say "10.5.0.0/16 is reachable via the
# router at 192.168.1.254", and no way to spread a prefix's traffic across
# several equal-cost gateways. ip.ad now implements a real IPv4 FIB:
#
#   * ip_route_lookup() does a genuine longest-prefix match — among every
#     route whose network matches the destination, the most specific (most
#     prefix bits) wins. A /32 host route beats a /24 subnet route beats
#     the /0 default route. ip_send() consults it for every outbound
#     packet (on-link -> ARP the dst, off-link -> ARP the route's gateway).
#   * ip_route_lookup_flow() adds ECMP: multiple routes to the SAME prefix
#     (same net/mask, distinct gateways) form an equal-cost nexthop group;
#     a deterministic FNV-1a hash of the (src, dst, proto) flow tuple picks
#     one nexthop so a given flow ALWAYS uses the same path (per-flow
#     consistency, never per-packet round-robin that would reorder a flow).
#
# HOW THIS TEST WORKS
# -------------------
# ip_init() (already on the boot path — no init/main.ad edit needed) scans
# the initramfs for /etc/iproute-test and /etc/ecmp-test markers and runs
# ip_fib_selftest() / ip_ecmp_selftest() (drivers/net/ip.ad) when present.
# Both markers are planted into ONE initramfs here, so a single QEMU boot
# exercises the REAL ip_route_lookup()/ip_route_lookup_flow() code paths.
#
# ip_fib_selftest() asserts (LPM, all of /32, /24 and the /0 default
# present at once, most-specific wins):
#   * a /16 subnet route resolves to its gateway (off-link)
#   * a /24 route beats an overlapping /16 (longest-prefix wins)
#   * a /32 host route beats the /24 and is on-link (ARP the dst)
#   * a destination with no specific route uses the /0 default gateway
#   * with no default route and no match, the lookup MISSES (unroutable)
#   * re-adding the same prefix replaces in place (no double slot)
#
# ip_ecmp_selftest() asserts (ECMP flow-stickiness):
#   * two /24 routes with different gws form a 2-nexthop group
#   * two different flows split across the two nexthops
#   * the SAME flow always selects the SAME nexthop (sticky / consistent)
#   * removing one nexthop leaves the group with the remaining one
#
# The markers are planted by importing build_initramfs as a module and
# appending to its FILES list (so NO edit to scripts/build_initramfs.py is
# required); they are absent from every other build, so default boots never
# run these self-tests.
#
# Pass marker:  [test_ipv4_fib] PASS
# Fail marker:  [test_ipv4_fib] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_ipv4_fib] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ipv4_fib] (2/3) Build initramfs (with /etc/iproute-test + /etc/ecmp-test markers) + kernel"
INIT_ELF=build/user/init.elf python3 - <<'PYEOF' >/dev/null
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
import build_initramfs as b
b.FILES.append(("/etc/iproute-test", b"1\n"))
b.FILES.append(("/etc/ecmp-test", b"1\n"))
archive = b.build_archive()
dest = Path("fs") / "initramfs_blob.S"
b.emit_asm(archive, dest)
PYEOF

python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Always rebuild a clean (marker-free) initramfs on exit so other tests /
# runs don't inherit the /etc/iproute-test or /etc/ecmp-test markers.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ipv4_fib] (3/3) Boot QEMU and run the FIB LPM + ECMP self-tests"
set +e
# A virtio-net device MUST be present: ip_init() (which runs the FIB
# self-tests) is only reached when virtio_net_init() succeeds in
# init/main.ad's net bring-up. Same device line test_net_iproute.sh uses.
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

# Strip ANSI/VT100 escapes so grep matches even through GRUB/fb control codes.
CLEAN_LOG=$(mktemp)
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.//g' "$LOG" > "$CLEAN_LOG"

echo "[test_ipv4_fib] --- ip-fib + ip-ecmp self-test output ---"
grep -E '\[ip-fib\]|\[ip-ecmp\]' "$CLEAN_LOG" || true
echo "[test_ipv4_fib] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_ipv4_fib] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure from either self-test is fatal.
if grep -qE '\[ip-fib\] .* FAIL|\[ip-ecmp\] .* FAIL' "$CLEAN_LOG"; then
    echo "[test_ipv4_fib] FAIL: a kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_ipv4_fib] PASS: $label"
    else
        echo "[test_ipv4_fib] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

# --- Longest-prefix-match (/32 > /24 > /16 > /0 default, all present) ---
check "/16 subnet route via gateway"          "[ip-fib] slash16-subnet-via-gw PASS"
check "/24 beats overlapping /16 (LPM)"        "[ip-fib] slash24-beats-slash16 PASS"
check "/32 host route on-link beats /24"       "[ip-fib] slash32-host-beats-slash24-onlink PASS"
check "/0 default route via gateway"           "[ip-fib] default-route-via-gw PASS"
check "no default + no match misses"           "[ip-fib] no-default-no-match-misses PASS"
check "same-prefix re-add replaces in place"   "[ip-fib] same-prefix-readd-replaces PASS"
check "FIB LPM self-test PASS-ALL banner"      "[ip-fib] PASS-ALL"

# --- ECMP flow-stickiness ---
check "two gws to same /24 form a 2-nexthop group"  "[ip-ecmp] two-gw-same-prefix-form-2nexthop-group PASS"
check "two flows split across both nexthops"        "[ip-ecmp] two-flows-split-across-both-nexthops PASS"
check "same flow → same nexthop (sticky)"           "[ip-ecmp] same-flow-same-nexthop-consistent PASS"
check "remove one nexthop leaves remaining"         "[ip-ecmp] remove-one-nexthop-leaves-remaining PASS"
check "ECMP self-test PASS-ALL banner"              "[ip-ecmp] PASS-ALL"

rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    echo "[test_ipv4_fib] FAIL"
    exit 1
fi

echo "[test_ipv4_fib] PASS — IPv4 FIB longest-prefix-match selects the most specific route (/32 > /24 > /16 > /0 default), distinguishes on-link (ARP dst) from via-gateway (ARP gw), misses cleanly when unrouted; ECMP groups multiple equal-cost gateways per prefix and a flow-tuple hash keeps each flow sticky to one nexthop"
