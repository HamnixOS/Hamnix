#!/usr/bin/env bash
# scripts/test_mm_pressure.sh — #167 memory-pressure subsystem:
# anonymous-page swap + page reclaim + an OOM killer, all native.
#
# Boots the kernel once with /etc/mm-test planted (ENABLE_MM_TEST=1);
# init/main.ad at boot:37.mm runs mm_pressure_selftest() (mm/reclaim.ad),
# which proves the WHOLE pressure path with unforgeable assertions:
#
#   PART A — SWAP ROUND-TRIP
#     A real demand-paged anonymous VMA is faulted in, stamped with a
#     deterministic per-byte pattern, and FNV-1a checksummed. reclaim
#     then evicts every page to swap (each PTE rewritten to a not-present
#     swap entry, each physical page freed). The test asserts:
#       * a specific evicted page's PTE IS a swap entry (not present),
#       * all 64 PTEs became swap entries,
#       * the swap store recorded 64 pageouts,
#       * after faulting every page back IN through the real swap-in path,
#         the region's checksum equals the pre-eviction checksum to the
#         bit — proving swap-out then swap-in restored the EXACT bytes.
#
#   PART B — OOM KILLER
#     Two real user tasks get demand VMAs with different resident sets
#     (48 vs 8 pages). The OOM killer is asked to pick a victim; the test
#     asserts it killed the LARGER-RSS task and that the system kept
#     running (the smaller task survives and the post-kill marker prints).
#
# Pass marker:  [test_mm] PASS
# Fail marker:  [test_mm] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_mm] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mm] (2/3) Build kernel with /etc/mm-test marker"
INIT_ELF=build/user/init.elf ENABLE_MM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mm] (3/3) Boot QEMU and run the memory-pressure self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_mm] --- mm self-test output ---"
grep -E "\[mm\]|\[swap\]|\[reclaim\]|\[oom\]" "$LOG" || true
echo "[test_mm] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mm] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[mm] FAIL" "$LOG"; then
    echo "[test_mm] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mm] PASS: $label"
    else
        echo "[test_mm] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "reclaim evicted all anon pages to swap" \
      "[mm] PASS: reclaim evicted all 64 anon pages to swap"
check "evicted page PTE is a swap entry" \
      "[mm] PASS: evicted page PTE is a swap entry"
check "all PTEs became swap entries" \
      "[mm] PASS: all 64 PTEs are swap entries"
check "swap recorded the pageouts" \
      "[mm] PASS: swap recorded 64 pageouts"
check "swap-in restored exact bytes (checksum match)" \
      "[mm] PASS: swap-in restored exact bytes"
check "reclaim driver evicted user-task pages" \
      "[mm] PASS: reclaim driver evicted"
check "OOM killed largest-RSS victim" \
      "[mm] PASS: OOM killed largest-RSS victim"
check "system survived OOM kill" \
      "[mm] PASS: system survived OOM kill"
# PART C — rmap + active/inactive LRU + LRU-driven reclaim
check "rmap records the anon page's mapper" \
      "[mm] PASS: rmap records mapper for anon page"
check "fault-in populates the LRU" \
      "[mm] PASS: 32 pages on LRU after fault-in"
check "second-chance promotes referenced pages" \
      "[mm] PASS: referenced pages promoted not evicted"
check "LRU-shrink evicts cold pages via rmap" \
      "[mm] PASS: LRU-shrink evicted 32 cold pages via rmap"
check "all part-C PTEs became swap entries" \
      "[mm] PASS: all 32 part-C PTEs are swap entries"
check "part-C swap-in restores exact bytes" \
      "[mm] PASS: part-C swap-in restored exact bytes via LRU/rmap"
# PART D — dirty-page accounting + balance_dirty_pages throttling
check "dirty-page accounting counts dirty pages" \
      "[mm] PASS: dirty accounting counted 32 dirty pages"
check "balance_dirty_pages throttles over dirty_ratio" \
      "[mm] PASS: balance_dirty_pages throttles over dirty_ratio"
check "clear_page_dirty drains the dirty count" \
      "[mm] PASS: clear_page_dirty drained the dirty count"
# PART E — Wave-3 VMA interval tree (O(log n) find/overlap/gap) + per-VMA lock
check "interval-tree find correct over many VMAs" \
      "[mm] PASS: vma interval-tree find correct over"
check "interval-tree height is logarithmic (O(log n), not O(n))" \
      "[mm] PASS: vma tree height="
check "interval-tree overlap query correct" \
      "[mm] PASS: vma interval-tree overlap query correct"
check "straddling-alias MAP_FIXED replace (#471 residual)" \
      "[mm] PASS: vma straddling-alias MAP_FIXED replace"
check "split keeps tree+list consistent" \
      "[mm] PASS: vma split keeps tree+list consistent"
check "per-VMA lock: same VMA serializes, distinct VMAs concurrent" \
      "[mm] PASS: per-VMA lock"
check "teardown removes test VMAs, tree stays consistent" \
      "[mm] PASS: vma teardown removed"
check "interval-tree/per-VMA-lock self-test complete" \
      "[mm] PASS: vma interval-tree + per-VMA-lock self-test complete"
check "self-test complete" \
      "[mm] PASS: pressure self-test complete"

if [ "$fail" -ne 0 ]; then
    echo "[test_mm] FAIL"
    exit 1
fi

echo "[test_mm] PASS — swap round-trip restores exact bytes AND the OOM killer relieves pressure"
