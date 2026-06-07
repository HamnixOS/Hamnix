#!/usr/bin/env bash
# scripts/test_bcache.sh — write-through block buffer cache regression test.
#
# Boots Hamnix under QEMU with the /etc/bcache-test marker planted and
# asserts that the new block buffer cache (kernel/block/blk.ad) works:
#
#   (1) A warm re-read of a span is served FROM THE CACHE: the device
#       rd_ios for that slot stays FLAT and the cache hit counter rises.
#   (2) A write keeps the cache coherent: a read-back after a write
#       returns the NEW bytes (no stale cached sector).
#
# The kernel self-test blk_bcache_selftest() emits explicit
# "[bcache] PASS:" / "[bcache] FAIL:" lines; this script greps for them.
#
# Gating: the self-test is gated behind /etc/bcache-test (planted only
# when ENABLE_BCACHE_TEST=1) inside the /etc/run-selftests master battery,
# so normal boots never run it.
#
# This test does NOT require /dev/kvm (it passes on TCG). TCG boots are
# slow, so the boot timeout is generous.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_bcache] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_bcache] (2/3) Build kernel with /etc/bcache-test marker"
ENABLE_BCACHE_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_bcache] (3/3) Boot QEMU and check buffer-cache self-test"
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

echo "[test_bcache] --- captured output ([bcache]-relevant lines) ---"
grep -E "\[bcache\]" "$LOG" || true
echo "[test_bcache] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_bcache] PASS: $label"
    else
        echo "[test_bcache] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

# The self-test ran at all (marker found + dispatched).
check_marker "self-test ran" "[bcache] self-test start"

# (1) Warm re-read served from cache, device rd_ios FLAT.
check_marker "warm read served from cache (device FLAT)" \
    "[bcache] PASS: warm read served from cache, device FLAT"

# (2) Write-through coherence: no stale cached sector after a write.
check_marker "write-through coherence (no stale sector)" \
    "[bcache] PASS: write-through coherence, no stale sector"

# Overall self-test verdict.
check_marker "overall self-test PASS" "[bcache] PASS: buffer-cache self-test complete"

# Hard fail if any FAIL line was emitted by the kernel self-test.
if grep -qE "\[bcache\] FAIL" "$LOG"; then
    echo "[test_bcache] FAIL: kernel emitted a [bcache] FAIL line" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_bcache] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_bcache] PASS — write-through block buffer cache: warm reads served from cache (device I/O flat), writes stay coherent"
