#!/usr/bin/env bash
# scripts/test_net_ecmp.sh — native IPv4 FIB ECMP (equal-cost multipath)
# self-test.
#
# THE GAP THIS COVERS
# -------------------
# The IPv4 FIB (drivers/net/ip.ad) does longest-prefix-match routing, but
# until now a prefix had exactly ONE nexthop: a second `route add` to the
# same (net, mask) just replaced the gateway. Real IPv4 hosts support
# equal-cost multipath (ECMP) — several gateways for the SAME prefix,
# forming a nexthop group — and spread flows across them. Linux selects a
# nexthop per FLOW (hash of the flow tuple), never per packet, so a given
# flow's packets always take the same path and never reorder.
#
# ip.ad now implements that: multiple routes to the same prefix (same
# net/mask, distinct gateways) form an equal-cost nexthop group (each
# nexthop in its own FIB slot). ip_route_lookup_flow() finds the longest
# matching prefix, counts the tying nexthops, and picks one by an FNV-1a
# hash of the (src, dst, proto) flow tuple — so a given flow always uses
# the same nexthop. ip_send() passes the live flow tuple, and ip_route_add
# APPENDS a new distinct gateway (replaces an exact-gw match in place).
#
# HOW THIS TEST WORKS
# -------------------
# ip_init() (already on the boot path — no init/main.ad edit needed)
# scans the initramfs for an /etc/ecmp-test marker and, when present,
# runs ip_ecmp_selftest() (drivers/net/ip.ad). That self-test drives the
# REAL ip_route_lookup_flow() ECMP path and asserts:
#   * two /24 routes with different gws form a 2-nexthop group
#   * two different flows split across the two nexthops (one each)
#   * the same flow always selects the same nexthop (per-flow consistency)
#   * removing one nexthop leaves the group with the remaining one
# and prints a final "[ip-ecmp] PASS-ALL".
#
# The /etc/ecmp-test marker is planted by importing build_initramfs as a
# module and appending to its FILES list (so NO edit to
# scripts/build_initramfs.py is required); the marker is absent from every
# other build, so default boots never run the self-test.
#
# Pass marker:  [test_net_ecmp] PASS
# Fail marker:  [test_net_ecmp] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_net_ecmp] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_net_ecmp] (2/3) Build initramfs (with /etc/ecmp-test marker) + kernel"
INIT_ELF=build/user/init.elf python3 - <<'PYEOF' >/dev/null
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
import build_initramfs as b
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
# runs don't inherit the /etc/ecmp-test marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_net_ecmp] (3/3) Boot QEMU and run the ECMP self-test"
set +e
# A virtio-net device MUST be present: ip_init() (which runs the ECMP
# self-test) is only reached when virtio_net_init() succeeds in
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

echo "[test_net_ecmp] --- ip-ecmp self-test output ---"
grep -E '\[ip-ecmp\]' "$CLEAN_LOG" || true
echo "[test_net_ecmp] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_net_ecmp] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[ip-ecmp]" "$CLEAN_LOG" && grep -qE '\[ip-ecmp\] .* FAIL' "$CLEAN_LOG"; then
    echo "[test_net_ecmp] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_net_ecmp] PASS: $label"
    else
        echo "[test_net_ecmp] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "two gws to same /24 form a 2-nexthop group"  "[ip-ecmp] two-gw-same-prefix-form-2nexthop-group PASS"
check "two flows split across both nexthops"        "[ip-ecmp] two-flows-split-across-both-nexthops PASS"
check "same flow → same nexthop (consistent)"       "[ip-ecmp] same-flow-same-nexthop-consistent PASS"
check "remove one nexthop leaves remaining"         "[ip-ecmp] remove-one-nexthop-leaves-remaining PASS"
check "ECMP self-test PASS-ALL banner"              "[ip-ecmp] PASS-ALL"

rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    echo "[test_net_ecmp] FAIL"
    exit 1
fi

echo "[test_net_ecmp] PASS — IPv4 FIB ECMP: multiple gateways for one prefix form an equal-cost nexthop group; a flow-tuple hash selects a per-flow-consistent nexthop (flows split across the group, the same flow never moves); removing a nexthop leaves the rest of the group intact"
