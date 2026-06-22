#!/usr/bin/env bash
# scripts/test_bh.sh — bottom-half stack (softirq / tasklet / workqueue /
# delayed-work / threaded-IRQ) regression.
#
# The whole proof is an in-kernel self-test: bh_selftest_run()
# (kernel/softirq.ad), gated on /etc/bh-test and the master
# /etc/run-selftests marker. We plant the marker with ENABLE_BH_TEST=1,
# build the kernel with the default init as /init, boot once under QEMU,
# and grep the serial log for the per-assertion PASS lines plus the final
# "[bh] SELFTEST PASS".
#
# Assertions proven (one [bh] PASS line each):
#   1. a raised softirq runs on the drain/IRQ-return path
#   2. a tasklet runs exactly once even when scheduled twice (coalesced),
#      via the TASKLET softirq
#   3. queue_work runs the work on a worker kthread and flush_work waits
#      for it to complete
#   4. delayed work fires only AFTER its delay (timer wheel -> TIMER
#      softirq -> queue_work -> worker)
#   5. a threaded-IRQ thread_fn runs in thread context, strictly after
#      the hard-IRQ top half
#
# Pass marker:  [test_bh] PASS
# Fail marker:  [test_bh] FAIL

. "$(dirname "$0")/_build_lock.sh"
# _kernel_iso.sh installs build/binshim/qemu-system-x86_64, which turns a
# `-kernel <elf64>` invocation into a BIOS GRUB `-cdrom <iso>` boot (QEMU's
# built-in -kernel multiboot1 loader rejects 64-bit ELFs / "knows VBE").
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_bh] (1/3) Build userland (default init)"
bash scripts/build_user.sh >/dev/null

echo "[test_bh] (2/3) Build kernel with /etc/bh-test marker planted"
INIT_ELF=build/user/init.elf ENABLE_BH_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_bh] (3/3) Boot QEMU and run the in-kernel bottom-half self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

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

echo "[test_bh] --- bottom-half self-test output ---"
grep -E "\[bh\]|\[softirq\]|\[workqueue\]" "$LOG" || true
echo "[test_bh] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_bh] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

fail=0
check() {
    local needle="$1"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_bh]   ok: $needle"
    else
        echo "[test_bh]   MISSING: $needle" >&2
        fail=1
    fi
}

# The softirq/workqueue cores must have come up.
check "[softirq] core up"
check "[workqueue] up:"

# Per-assertion PASS lines.
check "[bh] PASS softirq raised-and-ran"
check "[bh] PASS tasklet ran-once"
check "[bh] PASS queue_work ran-on-worker"
check "[bh] PASS delayed_work fired after"
check "[bh] PASS threaded-IRQ thread_fn ran in thread context"

# The overall verdict must be PASS and there must be no FAIL line.
check "[bh] SELFTEST PASS"
if grep -qE "\[bh\] (SELFTEST )?FAIL" "$LOG"; then
    echo "[test_bh] FAIL: a [bh] FAIL line appeared" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_bh] FAIL" >&2
    exit 1
fi
echo "[test_bh] PASS"
