#!/usr/bin/env bash
# scripts/test_buddy_coalesce.sh — buddy merge-on-free (block coalescing)
# regression for the physical page allocator (mm/page_alloc.ad).
#
# The proof is an in-kernel self-test, page_alloc_coalesce_test()
# (tests/mm_smoke.ad), run unconditionally at quiet early boot right after
# page_alloc_smoke_test(). It:
#   * allocates an order-3 run so the merge target's order-2 buddy is OWNED
#     (kept off every free list), making the assertions baseline-independent;
#   * frees the four order-0 quarters of the lower order-2 half and asserts
#     the cascade merges them back into ONE order-2 block (order0/order1
#     counts return to baseline, order2 gains exactly one block);
#   * asserts a follow-up alloc_pages(2) returns the EXACT original base —
#     only possible if the quarters coalesced (un-merged order-0 frees can
#     never satisfy an order-2 request from that address);
#   * returns all memory it took so allocator accounting is left as found.
#
# We boot the default-init kernel once under QEMU and grep the serial log
# for the per-assertion output plus the final "[buddy-coalesce] PASS",
# asserting no "[buddy-coalesce] FAIL" / "SELFTEST FAIL" line appeared.
#
# Pass marker:  [test_buddy_coalesce] PASS
# Fail marker:  [test_buddy_coalesce] FAIL

. "$(dirname "$0")/_build_lock.sh"
# _kernel_iso.sh installs build/binshim/qemu-system-x86_64, which turns a
# `-kernel <elf64>` invocation into a BIOS GRUB `-cdrom <iso>` boot (QEMU's
# built-in -kernel multiboot1 loader rejects 64-bit ELFs).
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_buddy_coalesce] (1/3) Build userland (default init)"
bash scripts/build_user.sh >/dev/null

echo "[test_buddy_coalesce] (2/3) Build kernel"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_buddy_coalesce] (3/3) Boot QEMU and run the in-kernel coalesce self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 120s qemu-system-x86_64 \
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

echo "[test_buddy_coalesce] --- coalesce self-test output ---"
grep -E "\[buddy-coalesce\]|buddy coalesce test" "$LOG" || true
echo "[test_buddy_coalesce] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_buddy_coalesce] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

fail=0
check() {
    local needle="$1"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_buddy_coalesce]   ok: $needle"
    else
        echo "[test_buddy_coalesce]   MISSING: $needle" >&2
        fail=1
    fi
}

check "Hamnix: buddy coalesce test"
check "[buddy-coalesce] PASS"

if grep -qE "\[buddy-coalesce\] (SELFTEST )?FAIL" "$LOG"; then
    echo "[test_buddy_coalesce] FAIL: a [buddy-coalesce] FAIL line appeared" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_buddy_coalesce] FAIL" >&2
    exit 1
fi
echo "[test_buddy_coalesce] PASS"
