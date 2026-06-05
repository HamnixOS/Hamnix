#!/usr/bin/env bash
# scripts/test_fqcodel.sh — native fq_codel (Flow Queue + CoDel AQM) qdisc
# self-test (Linux's default qdisc).
#
# Boots the kernel once with /etc/fqcodel-test planted (ENABLE_FQCODEL_TEST=1).
# init/main.ad at boot:37.fqcodel calls fqcodel_selftest() (drivers/net/
# fq_codel.ad), a fully in-memory test (NO external NIC required) that PROVES
# the core of fq_codel against an INJECTED virtual clock:
#
#   * FLOW QUEUEING: packets are hashed by flow key into one of N flow queues,
#     serviced by Deficit Round Robin (DRR) with a byte quantum and a
#     new-flows-before-old-flows preference, so a freshly arrived sparse flow
#     is serviced ahead of (and not starved by) a bulk flow.
#   * CoDel per flow queue: each dequeued packet's SOJOURN time
#     (dequeue_tick - enqueue_tick) is compared to TARGET; while sojourn stays
#     >= TARGET for >= INTERVAL the queue enters the dropping state and sheds
#     packets at the control-law cadence interval/sqrt(count) (a REAL integer
#     square root, no floats) — the cadence accelerates as the running drop
#     count grows — and dropping STOPS once sojourn falls back below TARGET.
#   * Properties, all verdicts from actual queue accounting:
#       - the integer isqrt control-law primitive is correct;
#       - flow isolation: a sparse flow is fully served early, not starved
#         behind a bulk flow's whole backlog (DRR fairness);
#       - CoDel drops: a standing queue above TARGET for >= INTERVAL triggers
#         drops whose cadence accelerates with the running count;
#       - a queue whose sojourn never exceeds TARGET suffers ZERO CoDel drops.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [fqcodel] PASS
# Fail marker:  [fqcodel] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_fqcodel] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fqcodel] (2/3) Build kernel with /etc/fqcodel-test marker"
INIT_ELF=build/user/init.elf ENABLE_FQCODEL_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fqcodel] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_fqcodel] --- captured (fqcodel lines) ---"
grep -E '\[fqcodel\]|\[boot:37.fqcodel\]' "$LOG" || true
echo "[test_fqcodel] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fqcodel] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[fqcodel] FAIL" "$LOG"; then
    echo "[test_fqcodel] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.fqcodel] FAIL" "$LOG"; then
    echo "[test_fqcodel] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_fqcodel] PASS: $label"
    else
        echo "[test_fqcodel] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[fqcodel] self-test start"
check "integer isqrt"            "[fqcodel] PASS isqrt"
check "flow isolation / DRR"     "[fqcodel] PASS flow-isolation"
check "codel drops"              "[fqcodel] PASS codel-drops"
check "codel recovery"           "[fqcodel] PASS codel-recovery"
check "control-law accelerates"  "[fqcodel] PASS control-law cadence accelerates"
check "good queue zero drops"    "[fqcodel] PASS good-queue"
check "fqcodel PASS banner"      "[fqcodel] PASS"
check "boot gate PASS"           "[boot:37.fqcodel] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_fqcodel] FAIL"
    exit 1
fi

echo "[test_fqcodel] PASS — native fq_codel (Flow Queue + CoDel AQM): packets are hashed by flow key into flow queues serviced by Deficit Round Robin with a new-flows-before-old-flows preference so a sparse flow is not starved by a bulk flow; each flow queue runs CoDel, dropping a standing queue (sojourn >= TARGET for >= INTERVAL) at the interval/sqrt(count) control law (a real integer square root) whose cadence accelerates with the running drop count and stops once sojourn recovers; and a queue below TARGET suffers zero drops"
