#!/usr/bin/env bash
# scripts/test_net_capacity.sh — native net-stack capacity self-test.
#
# THE GAPS THIS COVERS
# --------------------
# A census of the native network stack found three hardcoded capacity
# limits that silently drop / fail under modest concurrency. They are
# raised + made array-correct, and proven here end-to-end against the
# REAL kernel data structures (no live NIC required):
#
#   (a) drivers/net/ipv6.ad — IPv6 fragment reassembly was a SINGLE slot.
#       A second fragmented datagram from a different peer reset the slot
#       and dropped the first. It is now an IP6_REASM_CTX-context pool
#       (keyed by src/dst/id, LRU eviction — mirrors the IPv4 ip_reasm_*
#       pool). The test interleaves two fragmented datagrams from two
#       distinct sources and asserts BOTH reassemble byte-exactly.
#
#   (b) drivers/net/sock_compat.ad — the combined kernel socket table was 16
#       slots; the 17th socket() returned -ENFILE. Raised to KSOCK_MAX
#       (64) with all parallel per-slot arrays resized in lockstep. The
#       test allocates > 16 sockets and asserts none fail.
#
#   (c) drivers/net/udp.ad — the UDP datagram store was 8 sockets * 8
#       deep = 64 total; beyond that, arrivals were silently dropped.
#       Raised to UDS_MAX (32) * UDS_QUEUE_DEPTH (16) with every
#       companion metadata/payload array resized in lockstep. The test
#       queues > 64 datagrams across the pool with ZERO loss and
#       dequeues them all byte-exact.
#
# HOW THIS TEST WORKS
# -------------------
# ipv6_selftest() (drivers/net/ipv6.ad), already wired into the boot
# path's net_smoke_test and GATED on /etc/ipv6-test, chains
# netcap_selftest() when a /etc/netcap-test cpio marker is ALSO present.
# netcap_selftest() drives the three capacity proofs against the real
# kernel structures and prints, per check:
#     [netcap] <name> PASS    or    [netcap] <name> FAIL
# and a final:
#     [netcap] PASS           or    [netcap] FAIL
#
# Both markers are planted WITHOUT editing scripts/build_initramfs.py:
# ENABLE_IPV6_SELFTEST=1 plants /etc/ipv6-test, and the netcap marker is
# appended by importing build_initramfs as a module (same idiom as
# scripts/test_net_ipreasm.sh). The markers are absent from every other
# build, so default boots never run the self-test.
#
# A trailing QEMU rc=124 AFTER the markers print is benign (the kernel
# halts without powering off QEMU). We assert with `grep -a` because the
# boot log contains binary bytes.
#
# Pass marker:  [test_net_capacity] PASS
# Fail marker:  [test_net_capacity] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_net_capacity] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_net_capacity] (2/3) Build initramfs (/etc/ipv6-test + /etc/netcap-test) + kernel"
# Plant BOTH gate markers without editing scripts/build_initramfs.py:
# ENABLE_IPV6_SELFTEST=1 (env-gated inside build_initramfs) plants
# /etc/ipv6-test; the netcap marker is appended via module import, then
# we emit the same fs/initramfs_blob.S the normal build emits.
ENABLE_IPV6_SELFTEST=1 INIT_ELF=build/user/init.elf python3 - <<'PYEOF' >/dev/null
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
import build_initramfs as b
b.FILES.append(("/etc/netcap-test", b"1\n"))
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
# runs don't inherit either marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_net_capacity] (3/3) Boot QEMU with virtio-net and run the self-test"
set +e
# A virtio-net device must be present: ipv6_selftest() (which chains
# netcap_selftest) is reached from net_smoke_test, only after the net
# bring-up in init/main.ad succeeds. Same device line test_net_ipv6.sh
# uses.
timeout 60s qemu-system-x86_64 \
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

# Strip ANSI/VT100 escapes so grep matches even through fb control codes.
CLEAN_LOG=$(mktemp)
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.//g' "$LOG" > "$CLEAN_LOG"

echo "[test_net_capacity] --- netcap self-test output ---"
grep -a -E '\[netcap\]' "$CLEAN_LOG" || true
echo "[test_net_capacity] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_net_capacity] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -a -qE '\[netcap\] .* FAIL' "$CLEAN_LOG"; then
    echo "[test_net_capacity] FAIL: a kernel self-test check reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_net_capacity] PASS: $label"
    else
        echo "[test_net_capacity] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "(a) two concurrent IPv6 datagrams reassemble" "[netcap] ipv6-concurrent-reasm PASS"
check "(b) more than 16 sockets allocate"            "[netcap] socket-table-gt16 PASS"
check "(c) more than 64 UDP datagrams queue w/o loss" "[netcap] udp-queue-gt64 PASS"
check "overall netcap PASS banner"                   "[netcap] PASS"

rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    echo "[test_net_capacity] FAIL"
    exit 1
fi

echo "[test_net_capacity] PASS — IPv6 reassembly is a multi-context pool (two concurrent fragmented datagrams from distinct sources both reassemble), the kernel socket table holds >16 sockets, and the UDP datagram store queues >64 datagrams without loss"
