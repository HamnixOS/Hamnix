#!/usr/bin/env bash
# scripts/test_fcache.sh — Linux-parity fs caching layer regression test.
#
# Boots Hamnix under QEMU with the /etc/fcache-test marker planted and
# asserts the three new fs/fcache.ad caches work:
#
#   PAGE CACHE (address_space): a re-read of a faulted page is served FROM
#     THE CACHE (hit counter rises, no second backing read), and a
#     write+fsync+reread is COHERENT (the new bytes come back, never stale).
#   DCACHE (dentry cache): a repeated path lookup is cached (positive +
#     negative), a DIFFERENT namespace (different Pgrp) never gets a stale
#     hit, and a mount/rename/unlink generation bump invalidates the cache.
#   INODE CACHE: a stat hit returns the stored metadata; an invalidate
#     forces a re-fetch.
#
# The kernel self-test fcache_selftest() (fs/fcache.ad) emits explicit
# "[fcache] PASS:" / "[fcache] FAIL:" lines; this script greps for them.
#
# Gating: the self-test is gated behind /etc/fcache-test (planted only when
# ENABLE_FCACHE_TEST=1) at init/main.ad boot:37.fcache, so normal boots
# never run it. The self-test is pure in-RAM (a stub writeback sink) so it
# needs NO extra disk and does NOT require /dev/kvm (passes on TCG). TCG
# boots are slow, so the boot timeout is generous.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_fcache] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_fcache] (2/3) Build kernel with /etc/fcache-test marker"
ENABLE_FCACHE_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fcache] (3/3) Boot QEMU and check fs-cache self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 480s qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_fcache] --- captured output ([fcache]-relevant lines) ---"
grep -E "\[fcache\]" "$LOG" || true
echo "[test_fcache] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_fcache] PASS: $label"
    else
        echo "[test_fcache] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

check_marker "self-test ran" "[fcache] self-test start"

# PAGE CACHE
check_marker "page-cache warm read served from cache" \
    "[fcache] PASS: page-cache warm read served from cache"
check_marker "page-cache write+fsync coherent reread" \
    "[fcache] PASS: page-cache write+fsync coherent reread"
check_marker "page-cache invalidate drops inode pages" \
    "[fcache] PASS: page-cache invalidate dropped inode pages"

# INODE CACHE
check_marker "inode-cache hit returns stored metadata" \
    "[fcache] PASS: inode-cache hit returns stored metadata"
check_marker "inode-cache invalidate forces re-fetch" \
    "[fcache] PASS: inode-cache invalidate forces re-fetch"

# DCACHE
check_marker "dcache positive lookup cached" \
    "[fcache] PASS: dcache positive lookup cached"
check_marker "dcache different namespace no stale hit" \
    "[fcache] PASS: dcache different namespace no stale hit"
check_marker "dcache negative entry cached" \
    "[fcache] PASS: dcache negative entry cached"
check_marker "dcache gen bump invalidates" \
    "[fcache] PASS: dcache mount/rename gen bump invalidates"

# DCACHE RCU-WALK (lockless read path)
check_marker "rcu-walk lockless positive hit" \
    "[fcache] PASS: rcu-walk lockless positive hit"
check_marker "rcu-walk torn read falls back to ref-walk" \
    "[fcache] PASS: rcu-walk torn read falls back to ref-walk"
check_marker "rcu-walk namespace isolation holds" \
    "[fcache] PASS: rcu-walk namespace isolation holds"
check_marker "rcu-walk deferred free past grace period" \
    "[fcache] PASS: rcu-walk deferred free past grace period"
check_marker "rcu-walk reclaim left other entries intact" \
    "[fcache] PASS: rcu-walk reclaim left other entries intact"

# Overall verdict.
check_marker "overall self-test PASS" "[fcache] PASS: fs-cache self-test complete"

# Hard fail if any FAIL line was emitted by the kernel self-test.
if grep -qE "\[fcache\] FAIL" "$LOG"; then
    echo "[test_fcache] FAIL: kernel emitted a [fcache] FAIL line" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fcache] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_fcache] PASS — page cache (warm hit + write/fsync coherent), dcache (positive/negative + per-namespace isolation + gen invalidation), dcache RCU-walk (lockless hit + seqcount torn-read ref-walk fallback + call_rcu deferred free + namespace isolation), inode cache all green"
